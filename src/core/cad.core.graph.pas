unit CAD.Core.Graph;
{$mode objfpc}{$H+}

{ ROLE:      dependency graph between features (a DAG). Edge User -> Input
             means "User uses the result of Input".
  CALLED BY: TCADDocument (Link/Unlink/AddNode/RemoveNode, CollectDirty),
             TCADRecomputePlan (Deps/Users to build levels).
  CALLS:     nothing.
  THREADS:   UI thread only; read-only while a recompute runs.
  SPEED:     nodes are slot indices into arrays (no search). Walks use a
             visit stamp: a new walk increments one counter instead of
             clearing a visited array, so a walk costs only the nodes it sees. }

interface

uses
  SysUtils;

type
  TCADIntArray = array of LongInt;

  TCADDependencyGraph = class
  private
    FDeps: array of TCADIntArray;    { slot -> slots it uses (inputs) }
    FUsers: array of TCADIntArray;   { slot -> slots that use it }
    FAlive: array of Boolean;
    FStamp: array of LongWord;
    FStampValue: LongWord;
    FStack: TCADIntArray;            { reused walk stack, no allocation per walk }
    procedure EnsureSlot(ASlot: LongInt);
    function NextStamp: LongWord;
    function Reaches(AFrom, ATarget: LongInt): Boolean;
    function GetSlotCount: LongInt;
  public
    procedure AddNode(ASlot: LongInt);
    { Removes the node and its input edges. Fails (False) while it has users. }
    function RemoveNode(ASlot: LongInt): Boolean;
    function IsAlive(ASlot: LongInt): Boolean;
    { Rejects self links, duplicates and links that would close a cycle. }
    function TryLink(AUser, AInput: LongInt; out AError: string): Boolean;
    function Unlink(AUser, AInput: LongInt): Boolean;
    function HasLink(AUser, AInput: LongInt): Boolean;
    { AChanged plus every feature that uses them, directly or not.
      Each slot appears once; order is unspecified. }
    procedure CollectDirty(const AChanged: TCADIntArray; out ADirty: TCADIntArray);
    function Deps(ASlot: LongInt): TCADIntArray;
    function Users(ASlot: LongInt): TCADIntArray;
    function UserCount(ASlot: LongInt): Integer;
    property SlotCount: LongInt read GetSlotCount;
  end;

procedure CADIntAppend(var A: TCADIntArray; AValue: LongInt);
function CADIntRemove(var A: TCADIntArray; AValue: LongInt): Boolean;
function CADIntContains(const A: TCADIntArray; AValue: LongInt): Boolean;

implementation

procedure CADIntAppend(var A: TCADIntArray; AValue: LongInt);
var
  N: Integer;
begin
  N := Length(A);
  SetLength(A, N + 1);
  A[N] := AValue;
end;

function CADIntRemove(var A: TCADIntArray; AValue: LongInt): Boolean;
var
  I, N: Integer;
begin
  N := Length(A);
  for I := 0 to N - 1 do
    if A[I] = AValue then
    begin
      { Keep the order: the inputs order is the Compute argument order. }
      if I < N - 1 then
        Move(A[I + 1], A[I], (N - 1 - I) * SizeOf(LongInt));
      SetLength(A, N - 1);
      Exit(True);
    end;
  Result := False;
end;

function CADIntContains(const A: TCADIntArray; AValue: LongInt): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(A) do
    if A[I] = AValue then
      Exit(True);
  Result := False;
end;

procedure TCADDependencyGraph.EnsureSlot(ASlot: LongInt);
var
  N: LongInt;
begin
  if ASlot < Length(FAlive) then
    Exit;
  N := Length(FAlive);
  while N <= ASlot do
    N := N * 2 + 16;
  SetLength(FDeps, N);
  SetLength(FUsers, N);
  SetLength(FAlive, N);          { new entries are False }
  SetLength(FStamp, N);          { new entries are 0 }
end;

function TCADDependencyGraph.GetSlotCount: LongInt;
begin
  Result := Length(FAlive);
end;

function TCADDependencyGraph.NextStamp: LongWord;
var
  I: Integer;
begin
  Inc(FStampValue);
  if FStampValue = 0 then
  begin
    { Wrapped after 4 billion walks: clear once and start again. }
    for I := 0 to High(FStamp) do
      FStamp[I] := 0;
    FStampValue := 1;
  end;
  Result := FStampValue;
end;

procedure TCADDependencyGraph.AddNode(ASlot: LongInt);
begin
  EnsureSlot(ASlot);
  FAlive[ASlot] := True;
end;

function TCADDependencyGraph.IsAlive(ASlot: LongInt): Boolean;
begin
  Result := (ASlot >= 0) and (ASlot < Length(FAlive)) and FAlive[ASlot];
end;

function TCADDependencyGraph.RemoveNode(ASlot: LongInt): Boolean;
var
  I: Integer;
begin
  Result := IsAlive(ASlot) and (Length(FUsers[ASlot]) = 0);
  if not Result then
    Exit;
  for I := 0 to High(FDeps[ASlot]) do
    CADIntRemove(FUsers[FDeps[ASlot][I]], ASlot);
  SetLength(FDeps[ASlot], 0);
  FAlive[ASlot] := False;
end;

function TCADDependencyGraph.Reaches(AFrom, ATarget: LongInt): Boolean;
var
  Top, Node, I: Integer;
  Stamp: LongWord;
begin
  { Depth-first over input edges: does AFrom (transitively) use ATarget? }
  Stamp := NextStamp;
  if Length(FStack) < 16 then
    SetLength(FStack, 16);
  Top := 0;
  FStack[0] := AFrom;
  FStamp[AFrom] := Stamp;
  while Top >= 0 do
  begin
    Node := FStack[Top];
    Dec(Top);
    if Node = ATarget then
      Exit(True);
    for I := 0 to High(FDeps[Node]) do
      if FStamp[FDeps[Node][I]] <> Stamp then
      begin
        FStamp[FDeps[Node][I]] := Stamp;
        Inc(Top);
        if Top >= Length(FStack) then
          SetLength(FStack, Length(FStack) * 2);
        FStack[Top] := FDeps[Node][I];
      end;
  end;
  Result := False;
end;

function TCADDependencyGraph.TryLink(AUser, AInput: LongInt; out AError: string): Boolean;
begin
  AError := '';
  if not (IsAlive(AUser) and IsAlive(AInput)) then
    AError := 'link to a missing feature'
  else if AUser = AInput then
    AError := 'a feature cannot use itself'
  else if CADIntContains(FDeps[AUser], AInput) then
    AError := 'link already exists'
  else if Reaches(AInput, AUser) then
    AError := 'link would create a cycle';
  Result := AError = '';
  if not Result then
    Exit;
  CADIntAppend(FDeps[AUser], AInput);
  CADIntAppend(FUsers[AInput], AUser);
end;

function TCADDependencyGraph.Unlink(AUser, AInput: LongInt): Boolean;
begin
  Result := IsAlive(AUser) and IsAlive(AInput) and CADIntRemove(FDeps[AUser], AInput);
  if Result then
    CADIntRemove(FUsers[AInput], AUser);
end;

function TCADDependencyGraph.HasLink(AUser, AInput: LongInt): Boolean;
begin
  Result := IsAlive(AUser) and CADIntContains(FDeps[AUser], AInput);
end;

procedure TCADDependencyGraph.CollectDirty(const AChanged: TCADIntArray;
  out ADirty: TCADIntArray);
var
  Stamp: LongWord;
  Head, Count, I, Node, U: Integer;
begin
  { Breadth-first over user edges; ADirty doubles as the queue. }
  ADirty := nil;
  SetLength(ADirty, 16);
  Count := 0;
  Stamp := NextStamp;
  for I := 0 to High(AChanged) do
  begin
    Node := AChanged[I];
    if IsAlive(Node) and (FStamp[Node] <> Stamp) then
    begin
      FStamp[Node] := Stamp;
      if Count >= Length(ADirty) then
        SetLength(ADirty, Count * 2);
      ADirty[Count] := Node;
      Inc(Count);
    end;
  end;
  Head := 0;
  while Head < Count do
  begin
    Node := ADirty[Head];
    Inc(Head);
    for I := 0 to High(FUsers[Node]) do
    begin
      U := FUsers[Node][I];
      if FStamp[U] <> Stamp then
      begin
        FStamp[U] := Stamp;
        if Count >= Length(ADirty) then
          SetLength(ADirty, Count * 2);
        ADirty[Count] := U;
        Inc(Count);
      end;
    end;
  end;
  SetLength(ADirty, Count);
end;

function TCADDependencyGraph.Deps(ASlot: LongInt): TCADIntArray;
begin
  Result := FDeps[ASlot];
end;

function TCADDependencyGraph.Users(ASlot: LongInt): TCADIntArray;
begin
  Result := FUsers[ASlot];
end;

function TCADDependencyGraph.UserCount(ASlot: LongInt): Integer;
begin
  if not IsAlive(ASlot) then
    Exit(0);
  Result := Length(FUsers[ASlot]);
end;

end.
