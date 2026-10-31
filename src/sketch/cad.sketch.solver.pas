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
function SumSq(const AR: array of Double): Double;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(AR) do
    Result := Result + Sqr(AR[I]);
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
