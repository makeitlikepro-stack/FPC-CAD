unit CAD.Sketch.Solver;
{$mode objfpc}{$H+}

{ ROLE:      solves a sketch: moves the free numbers until every active
             constraint holds, then reports degrees of freedom, redundant and
             conflicting constraints.
  CALLED BY: sketch features, the sketch editor (later), tests/sketch.
  CALLS:     CAD.Sketch.Model, CAD.Sketch.Constraints.
  THREADS:   one call per sketch at a time; no globals.
  SPEED:     Levenberg-Marquardt on the minimum-norm step
               (J J^T + lambda I) y = -r,  dx = J^T y
             so an under-constrained sketch moves as little as possible
             (drag friendly). J is sparse (<= 8 entries per row, CSR);
             J J^T = dot products of short rows (rows^2 x 64 at most).
             Cholesky on rows x rows (sketches have hundreds of rows, not
             thousands; large sketches: see PERFORMANCE.md, later sparse). Diagnostics (rank by row
             Gram-Schmidt) run once after the solve and can be turned off.

  Algorithm checked first with a NumPy prototype (rectangle, redundant and
  conflicting dimension, slot of 2 lines + 2 tangent arcs). }

interface

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Constraints;

type
  TCADSketchSolveStatus = (
    cssSolved,        { every constraint holds }
    cssConflicting,   { some constraints cannot hold together: see Conflicting }
    cssFailed         { no convergence (bad start or near-singular) }
  );

  TCADSketchSolveOptions = record
    MaxIterations: Integer;
    Tolerance: Double;          { largest residual allowed, mm / rad }
    Diagnose: Boolean;          { DOF, redundant and conflicting lists }
  end;

  TCADSketchSolveResult = record
    Status: TCADSketchSolveStatus;
    Iterations: Integer;
    MaxResidual: Double;
    FreeParams: Integer;        { numbers the solver may change }
    Rows: Integer;              { equations }
    DOF: Integer;               { free params - rank (-1 when not diagnosed) }
    Redundant: array of Integer;   { constraint indices implied by earlier ones }
    Conflicting: array of Integer; { constraint indices that do not hold }
    Milliseconds: QWord;
  end;

function CADDefaultSolveOptions: TCADSketchSolveOptions;
function CADSolveSketch(S: TCADSketch): TCADSketchSolveResult; overload;
function CADSolveSketch(S: TCADSketch; const AOptions: TCADSketchSolveOptions): TCADSketchSolveResult; overload;
function CADSolveStatusText(AStatus: TCADSketchSolveStatus): string;

implementation

type
  TRowInfo = record
    Constraint: Integer;          { index in the sketch }
    Sub: Integer;                 { row 0 or 1 of that constraint }
  end;

  TJEntry = record
    Col: Integer;
    Val: Double;
  end;

  { Working data of one solve. }
  TSolveWork = class
  public
    S: TCADSketch;
    X: array of Double;           { all params (fixed ones too) }
    ColOfParam: array of Integer; { -1 = fixed }
    ParamOfCol: array of Integer;
    Cons: array of Integer;       { active constraint indices }
    ConsRow0: array of Integer;   { first row of each active constraint }
    Rows: array of TRowInfo;
    M, N: Integer;                { rows, free columns }
    R: array of Double;           { residuals }
    JRowStart: array of Integer;  { CSR: entries of row i = [start[i], start[i+1]) }
    JEntries: array of TJEntry;
    A: array of Double;           { M x M, row major }
    procedure Setup(ASketch: TCADSketch);
    function Residuals(var AR: array of Double): Double;    { returns max |r| }
    procedure Jacobian;
    procedure BuildNormal(ALambda: Double);
    function Cholesky: Boolean;
    procedure CholSolve(var B: array of Double);
  end;

function CADDefaultSolveOptions: TCADSketchSolveOptions;
begin
  Result.MaxIterations := 100;
  Result.Tolerance := 1e-9;
  Result.Diagnose := True;
end;

function CADSolveStatusText(AStatus: TCADSketchSolveStatus): string;
begin
  case AStatus of
    cssSolved: Result := 'solved';
    cssConflicting: Result := 'conflicting constraints';
  else
    Result := 'not converged';
  end;
end;

procedure TSolveWork.Setup(ASketch: TCADSketch);
var
  I, K, J, NRows: Integer;
begin
  S := ASketch;
  SetLength(X, S.ParamCount);
  SetLength(ColOfParam, S.ParamCount);
  SetLength(ParamOfCol, S.ParamCount);
  N := 0;
  for I := 0 to S.ParamCount - 1 do
  begin
    X[I] := S.Params[I];
    if S.Fixed[I] then
      ColOfParam[I] := -1
    else
    begin
      ColOfParam[I] := N;
      ParamOfCol[N] := I;
      Inc(N);
    end;
  end;
  SetLength(Cons, S.ConstraintCount);
  SetLength(ConsRow0, S.ConstraintCount);
  SetLength(Rows, CAD_SK_MAX_ROWS * S.ConstraintCount);
  K := 0;
  M := 0;
  for I := 0 to S.ConstraintCount - 1 do
    if S.Constraints[I].Active then
    begin
      Cons[K] := I;
      ConsRow0[K] := M;
      NRows := CADConstraintRows(S.Constraints[I].Kind);
      for J := 0 to NRows - 1 do
      begin
        Rows[M].Constraint := I;
        Rows[M].Sub := J;
        Inc(M);
      end;
      Inc(K);
    end;
  SetLength(Cons, K);
  SetLength(ConsRow0, K);
  SetLength(R, M);
  SetLength(JRowStart, M + 1);
  SetLength(JEntries, M * CAD_SK_MAX_PARAMS);
  SetLength(A, M * M);
end;

function TSolveWork.Residuals(var AR: array of Double): Double;
var
  K, J, Row: Integer;
  RR: TCADSkResidual;
begin
  Result := 0;
  for K := 0 to High(Cons) do
  begin
    CADConstraintResiduals(S, S.Constraints[Cons[K]], PCADSkDoubleArray(@X[0]), RR);
    Row := ConsRow0[K];
    for J := 0 to CADConstraintRows(S.Constraints[Cons[K]].Kind) - 1 do
    begin
      AR[Row + J] := RR[J];
      Result := Max(Result, Abs(RR[J]));
    end;
  end;
end;

procedure TSolveWork.Jacobian;
var
  K, J, P, Col, NRows, Row, E: Integer;
  C: TCADSketchConstraint;
  L: TCADSkParamList;
  RP, RM: TCADSkResidual;
  Keep, H: Double;
  Count: array[0..CAD_SK_MAX_ROWS - 1] of Integer;
begin
  E := 0;
  for K := 0 to High(Cons) do
  begin
    C := S.Constraints[Cons[K]];
    NRows := CADConstraintRows(C.Kind);
    Row := ConsRow0[K];
    CADConstraintParams(S, C, L);
    { The rows of one constraint share the columns. First each row gets a
      slot of L.Count entries; fixed numbers leave gaps that are closed
      below, so every row is contiguous (CSR). }
    for J := 0 to NRows - 1 do
    begin
      Count[J] := 0;
      JRowStart[Row + J] := E + J * L.Count;
    end;
    for P := 0 to L.Count - 1 do
    begin
      Col := ColOfParam[L.Idx[P]];
      if Col < 0 then
        Continue;
      Keep := X[L.Idx[P]];
      H := 1e-7 * Max(1.0, Abs(Keep));
      X[L.Idx[P]] := Keep + H;
      CADConstraintResiduals(S, C, PCADSkDoubleArray(@X[0]), RP);
      X[L.Idx[P]] := Keep - H;
      CADConstraintResiduals(S, C, PCADSkDoubleArray(@X[0]), RM);
      X[L.Idx[P]] := Keep;
      for J := 0 to NRows - 1 do
      begin
        JEntries[JRowStart[Row + J] + Count[J]].Col := Col;
        JEntries[JRowStart[Row + J] + Count[J]].Val := (RP[J] - RM[J]) / (2 * H);
        Inc(Count[J]);
      end;
    end;
    for J := 1 to NRows - 1 do
    begin
      for P := 0 to Count[J] - 1 do
        JEntries[JRowStart[Row] + Count[0] * J + P] := JEntries[JRowStart[Row + J] + P];
      JRowStart[Row + J] := JRowStart[Row] + Count[0] * J;
    end;
    E := JRowStart[Row] + Count[0] * NRows;
  end;
  JRowStart[M] := E;
end;

procedure TSolveWork.BuildNormal(ALambda: Double);
var
  I, J, Q1, Q2: Integer;
  Sum: Double;
begin
  { (J J^T)[i, j] = dot(row i, row j) over the short sparse rows. }
  for I := 0 to M - 1 do
    for J := 0 to I do
    begin
      Sum := 0;
      for Q1 := JRowStart[I] to JRowStart[I + 1] - 1 do
        for Q2 := JRowStart[J] to JRowStart[J + 1] - 1 do
          if JEntries[Q1].Col = JEntries[Q2].Col then
            Sum := Sum + JEntries[Q1].Val * JEntries[Q2].Val;
      A[I * M + J] := Sum;
      A[J * M + I] := Sum;
    end;
  for I := 0 to M - 1 do
    A[I * M + I] := A[I * M + I] + ALambda;
end;

function TSolveWork.Cholesky: Boolean;
var
  I, J, K: Integer;
  Sum: Double;
begin
  { In place, lower triangle: A = L L^T. }
  for J := 0 to M - 1 do
  begin
    Sum := A[J * M + J];
    for K := 0 to J - 1 do
      Sum := Sum - Sqr(A[J * M + K]);
    if Sum <= 1e-300 then
      Exit(False);
    A[J * M + J] := Sqrt(Sum);
    for I := J + 1 to M - 1 do
    begin
      Sum := A[I * M + J];
      for K := 0 to J - 1 do
        Sum := Sum - A[I * M + K] * A[J * M + K];
      A[I * M + J] := Sum / A[J * M + J];
    end;
  end;
  Result := True;
end;

procedure TSolveWork.CholSolve(var B: array of Double);
var
  I, K: Integer;
  Sum: Double;
begin
  for I := 0 to M - 1 do
  begin
    Sum := B[I];
    for K := 0 to I - 1 do
      Sum := Sum - A[I * M + K] * B[K];
    B[I] := Sum / A[I * M + I];
  end;
  for I := M - 1 downto 0 do
  begin
    Sum := B[I];
    for K := I + 1 to M - 1 do
      Sum := Sum - A[K * M + I] * B[K];
    B[I] := Sum / A[I * M + I];
  end;
end;

{ Rank and redundant rows by modified Gram-Schmidt over the rows in
  constraint order: a row inside the span of the earlier rows is redundant. }
procedure Diagnose(W: TSolveWork; ATol: Double; var AResult: TCADSketchSolveResult);
var
  Basis: array of array of Double;
  V: array of Double;
  Rank, I, J, Q, NRed, NConf, Last: Integer;
  D, Nrm, Nrm0: Double;
  RedRow: array of Boolean;
  ConsBad: array of Boolean;
begin
  SetLength(Basis, Min(W.M, W.N));
  SetLength(V, W.N);
  SetLength(RedRow, W.M);
  Rank := 0;
  for I := 0 to W.M - 1 do
  begin
    for J := 0 to W.N - 1 do
      V[J] := 0;
    for Q := W.JRowStart[I] to W.JRowStart[I + 1] - 1 do
      V[W.JEntries[Q].Col] := V[W.JEntries[Q].Col] + W.JEntries[Q].Val;
    Nrm0 := 0;
    for J := 0 to W.N - 1 do
      Nrm0 := Nrm0 + Sqr(V[J]);
    Nrm0 := Sqrt(Nrm0);
    for Q := 0 to Rank - 1 do
    begin
      D := 0;
      for J := 0 to W.N - 1 do
        D := D + V[J] * Basis[Q][J];
      for J := 0 to W.N - 1 do
        V[J] := V[J] - D * Basis[Q][J];
    end;
    Nrm := 0;
    for J := 0 to W.N - 1 do
      Nrm := Nrm + Sqr(V[J]);
    Nrm := Sqrt(Nrm);
    if (Rank < Length(Basis)) and (Nrm > 1e-8 * Max(1.0, Nrm0)) then
    begin
      SetLength(Basis[Rank], W.N);
      for J := 0 to W.N - 1 do
        Basis[Rank][J] := V[J] / Nrm;
      Inc(Rank);
    end
    else
      RedRow[I] := True;
  end;
  AResult.DOF := W.N - Rank;

  { Redundant = a row of the constraint lies in the span of earlier rows.
    Conflicting = a row does not hold (only when the solve failed). }
  NRed := 0;
  Last := -1;
  SetLength(AResult.Redundant, W.M);
  for I := 0 to W.M - 1 do
    if RedRow[I] and (W.Rows[I].Constraint <> Last) then
    begin
      Last := W.Rows[I].Constraint;
      AResult.Redundant[NRed] := Last;
      Inc(NRed);
    end;
  SetLength(AResult.Redundant, NRed);
  SetLength(ConsBad, W.S.ConstraintCount);
  NConf := 0;
  SetLength(AResult.Conflicting, W.M);
  if AResult.Status <> cssSolved then
    for I := 0 to W.M - 1 do
      if (Abs(W.R[I]) > ATol) and not ConsBad[W.Rows[I].Constraint] then
      begin
        ConsBad[W.Rows[I].Constraint] := True;
        AResult.Conflicting[NConf] := W.Rows[I].Constraint;
        Inc(NConf);
      end;
  SetLength(AResult.Conflicting, NConf);
  if (AResult.Status = cssFailed) and (NRed > 0) and (NConf > 0) then
    AResult.Status := cssConflicting;
end;

function SumSq(const AR: array of Double): Double;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(AR) do
    Result := Result + Sqr(AR[I]);
end;

function CADSolveSketch(S: TCADSketch): TCADSketchSolveResult;
begin
  Result := CADSolveSketch(S, CADDefaultSolveOptions);
end;

function CADSolveSketch(S: TCADSketch; const AOptions: TCADSketchSolveOptions): TCADSketchSolveResult;
var
  W: TSolveWork;
  T0: QWord;
  Lambda, Err, SSE, NewErr, NewSSE: Double;
  Y, Keep, RTrial: array of Double;
  I, Q, It, Col: Integer;
begin
  T0 := GetTickCount64;
  Result := Default(TCADSketchSolveResult);
  Result.DOF := -1;
  W := TSolveWork.Create;
  try
    W.Setup(S);
    Result.FreeParams := W.N;
    Result.Rows := W.M;
    SetLength(Y, W.M);
    SetLength(Keep, System.Length(W.X));
    SetLength(RTrial, W.M);
    Err := W.Residuals(W.R);           { largest residual: the stop test }
    SSE := SumSq(W.R);                 { sum of squares: the accept test }
    Lambda := 1e-3;
    It := 0;
    if (W.M > 0) and (W.N > 0) and (Err > AOptions.Tolerance) then
    begin
      W.Jacobian;
      while (It < AOptions.MaxIterations) and (Err > AOptions.Tolerance) do
      begin
        Inc(It);
        W.BuildNormal(Lambda);
        if not W.Cholesky then
        begin
          Lambda := Lambda * 10;
          if Lambda > 1e12 then
            Break;
          Continue;
        end;
        for I := 0 to W.M - 1 do
          Y[I] := -W.R[I];
        W.CholSolve(Y);
        { trial x = x + J^T y }
        for I := 0 to High(W.X) do
          Keep[I] := W.X[I];
        for I := 0 to W.M - 1 do
          for Q := W.JRowStart[I] to W.JRowStart[I + 1] - 1 do
          begin
            Col := W.ParamOfCol[W.JEntries[Q].Col];
            W.X[Col] := W.X[Col] + W.JEntries[Q].Val * Y[I];
          end;
        NewErr := W.Residuals(RTrial);
        NewSSE := SumSq(RTrial);
        if NewSSE < SSE then
        begin
          for I := 0 to W.M - 1 do
            W.R[I] := RTrial[I];
          Err := NewErr;
          SSE := NewSSE;
          Lambda := Max(Lambda / 3, 1e-12);
          if Err > AOptions.Tolerance then
            W.Jacobian;
        end
        else
        begin
          for I := 0 to High(W.X) do
            W.X[I] := Keep[I];
          Lambda := Lambda * 4;
          if Lambda > 1e12 then
            Break;
        end;
      end;
    end;
    Result.Iterations := It;
    Result.MaxResidual := Err;
    if Err <= AOptions.Tolerance then
      Result.Status := cssSolved
    else
      Result.Status := cssFailed;
    S.SetParams(W.X);
    if AOptions.Diagnose then
    begin
      W.Jacobian;
      Diagnose(W, Max(AOptions.Tolerance * 1000, 1e-7), Result);
    end;
  finally
    W.Free;
  end;
  Result.Milliseconds := GetTickCount64 - T0;
end;

end.
