unit CAD.Core.RecomputePlan;
{$mode objfpc}{$H+}

{ ROLE:      orders the dirty features into levels. Level 0 needs nothing
             that is dirty; level N needs only levels < N. Features inside one
             level are independent, so they can be computed in parallel.
  CALLED BY: TCADDocument.Recompute.
  CALLS:     CAD.Core.Graph (Deps/Users).
  THREADS:   UI thread, before the workers start.
  SPEED:     Kahn's algorithm on the dirty subgraph only: O(dirty nodes +
             their edges). A local slot -> position map replaces searching. }

interface

uses
  SysUtils, CAD.Core.Graph;

type
  TCADRecomputePlan = class
  private
    FLevels: array of TCADIntArray;
    FFeatureCount: Integer;
    function GetLevelCount: Integer;
    function GetLevel(AIndex: Integer): TCADIntArray;
  public
    procedure Clear;
    { ADirty must be closed under "users" (TCADDependencyGraph.CollectDirty). }
    procedure Build(AGraph: TCADDependencyGraph; const ADirty: TCADIntArray);
    property LevelCount: Integer read GetLevelCount;
    property Levels[AIndex: Integer]: TCADIntArray read GetLevel;
    property FeatureCount: Integer read FFeatureCount;
  end;

implementation

procedure TCADRecomputePlan.Clear;
begin
  FLevels := nil;
  FFeatureCount := 0;
end;

function TCADRecomputePlan.GetLevelCount: Integer;
begin
  Result := Length(FLevels);
end;

function TCADRecomputePlan.GetLevel(AIndex: Integer): TCADIntArray;
begin
  Result := FLevels[AIndex];
end;

procedure TCADRecomputePlan.Build(AGraph: TCADDependencyGraph; const ADirty: TCADIntArray);
var
  SlotPos: TCADIntArray;           { slot -> index in ADirty, -1 = not dirty }
  Waiting: TCADIntArray;       { per dirty index: dirty inputs not computed yet }
  Current, Next: TCADIntArray;
  I, J, K, Node, U, Placed: Integer;
  D, Us: TCADIntArray;
begin
  Clear;
  if Length(ADirty) = 0 then
    Exit;
  SetLength(SlotPos, AGraph.SlotCount);
  for I := 0 to High(SlotPos) do
    SlotPos[I] := -1;
  for I := 0 to High(ADirty) do
    SlotPos[ADirty[I]] := I;

  SetLength(Waiting, Length(ADirty));
  Current := nil;
  for I := 0 to High(ADirty) do
  begin
    D := AGraph.Deps(ADirty[I]);
    Waiting[I] := 0;
    for J := 0 to High(D) do
      if SlotPos[D[J]] >= 0 then
        Inc(Waiting[I]);
    if Waiting[I] = 0 then
      CADIntAppend(Current, ADirty[I]);
  end;

  Placed := 0;
  while Length(Current) > 0 do
  begin
    SetLength(FLevels, Length(FLevels) + 1);
    FLevels[High(FLevels)] := Current;
    Inc(Placed, Length(Current));
    Next := nil;
    for K := 0 to High(Current) do
    begin
      Node := Current[K];
      Us := AGraph.Users(Node);
      for J := 0 to High(Us) do
      begin
        U := Us[J];
        if SlotPos[U] < 0 then
          Continue;
        Dec(Waiting[SlotPos[U]]);
        if Waiting[SlotPos[U]] = 0 then
          CADIntAppend(Next, U);
      end;
    end;
    Current := Next;
  end;
  FFeatureCount := Placed;
  { The graph rejects cycles, so every dirty node is placed. }
  if Placed <> Length(ADirty) then
    raise Exception.CreateFmt('Recompute plan placed %d of %d features (cycle?)',
      [Placed, Length(ADirty)]);
end;

end.
