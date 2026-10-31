unit CAD.View.Sync;
{$mode objfpc}{$H+}

{ ROLE:      keeps the viewport objects equal to the document's shown results:
             one object per feature, object id = slot + 1.
  CALLED BY: the application after TCADDocument.Recompute (stage 4 step 3),
             tests/view.
  CALLS:     CAD.Core.Document (Find, IsShown, Output), the mesh filler
             (CAD.View.MeshConvert.CADFillMeshFromResult), a TCADViewTarget
             (CAD.View.ViewportTarget on the engine, a fake in tests).
  THREADS:   UI thread only, never during Recompute (results may be freed by
             the cache while workers run).
  SPEED:     a result is converted only when it differs from the one already
             shown (pointer and cache key); hide/show only flips visibility,
             so showing the same result again costs nothing. One pass over
             the slots, no allocation when nothing changed. }

interface

uses
  SysUtils, CAD.Core.Ids, CAD.Core.Feature, CAD.Core.Document,
  OpenGL.Render.Viewport3DMeshData;

type
  { What the sync needs from a viewport. }
  TCADViewTarget = class
  public
    { Mesh of object AObjectId; creates an empty object when missing. }
    function MeshFor(AObjectId: Cardinal): TV3DMeshData; virtual; abstract;
    { No-op for an object that does not exist. }
    procedure SetObjectVisible(AObjectId: Cardinal; AVisible: Boolean); virtual; abstract;
    { Called once per Sync when anything changed (redraw). }
    procedure Changed; virtual; abstract;
  end;

  { Fills AMesh (cleared by the filler) from a display-ready result. }
  TCADMeshFiller = function(AResult: TCADResult; AMesh: TV3DMeshData;
    out AError: string): Boolean;

  TCADViewSyncReport = record
    Updated: Integer;       { converted (new or changed result) }
    Shown: Integer;         { made visible again without converting }
    Hidden: Integer;
    Unchanged: Integer;     { shown and identical: nothing done }
    Failed: Integer;        { filler failed: object hidden, see LastError }
    Milliseconds: QWord;
  end;

  TCADViewSlotState = record
    Shown: TCADResult;      { last converted result (not owned; compare only) }
    Key: TCADHash;
    HasObject: Boolean;
    Visible: Boolean;
  end;
  PCADViewSlotState = ^TCADViewSlotState;

  TCADViewSync = class
  private
    FDoc: TCADDocument;
    FTarget: TCADViewTarget;
    FFiller: TCADMeshFiller;
    FSlots: array of TCADViewSlotState;
    FLastError: string;
    procedure SyncSlot(ASlot: LongInt; var AReport: TCADViewSyncReport);
    procedure SetVisible(ASlot: LongInt; AVisible: Boolean);
  public
    constructor Create(ADoc: TCADDocument; ATarget: TCADViewTarget; AFiller: TCADMeshFiller);
    function Sync: TCADViewSyncReport;
    { Forget everything (after the viewport objects were cleared). }
    procedure Reset;
    class function ObjectIdOf(const AId: TCADId): Cardinal;
    { CADNoId for object 0 or an id that was never a feature slot. }
    class function FeatureOf(AObjectId: Cardinal): TCADId;
    property LastError: string read FLastError;
  end;

implementation

constructor TCADViewSync.Create(ADoc: TCADDocument; ATarget: TCADViewTarget;
  AFiller: TCADMeshFiller);
begin
  inherited Create;
  FDoc := ADoc;
  FTarget := ATarget;
  FFiller := AFiller;
end;

class function TCADViewSync.ObjectIdOf(const AId: TCADId): Cardinal;
begin
  Result := Cardinal(AId.Slot + 1);
end;

class function TCADViewSync.FeatureOf(AObjectId: Cardinal): TCADId;
begin
  if (AObjectId = 0) or (AObjectId > Cardinal(High(LongInt))) then
    Exit(CADNoId);
  Result := CADId(LongInt(AObjectId) - 1);
end;

procedure TCADViewSync.Reset;
begin
  FSlots := nil;
end;

procedure TCADViewSync.SetVisible(ASlot: LongInt; AVisible: Boolean);
begin
  FTarget.SetObjectVisible(Cardinal(ASlot + 1), AVisible);
  FSlots[ASlot].Visible := AVisible;
end;

procedure TCADViewSync.SyncSlot(ASlot: LongInt; var AReport: TCADViewSyncReport);
var
  F: TCADFeature;
  R: TCADResult;
  P: PCADViewSlotState;
  Want: Boolean;
  Err: string;
begin
  F := FDoc.Find(CADId(ASlot));
  R := nil;
  if F <> nil then
    R := F.Output;
  Want := (R <> nil) and FDoc.IsShown(F.Id) and R.DisplayReady;
  P := @FSlots[ASlot];
  if not Want then
  begin
    if P^.Visible then
    begin
      SetVisible(ASlot, False);
      Inc(AReport.Hidden);
    end;
    Exit;
  end;
  if P^.HasObject and (P^.Shown = R) and (P^.Key = R.Key) then
  begin
    if P^.Visible then
      Inc(AReport.Unchanged)
    else
    begin
      SetVisible(ASlot, True);
      Inc(AReport.Shown);
    end;
    Exit;
  end;
  P^.HasObject := True;
  if FFiller(R, FTarget.MeshFor(Cardinal(ASlot + 1)), Err) then
  begin
    P^.Shown := R;
    P^.Key := R.Key;
    if not P^.Visible then
      SetVisible(ASlot, True);
    Inc(AReport.Updated);
  end
  else
  begin
    P^.Shown := nil;            { try again next Sync }
    if P^.Visible then
      SetVisible(ASlot, False);
    FLastError := Format('%s: %s', [F.Name, Err]);
    Inc(AReport.Failed);
  end;
end;

function TCADViewSync.Sync: TCADViewSyncReport;
var
  S, Old: LongInt;
  T0: QWord;
begin
  T0 := GetTickCount64;
  Result := Default(TCADViewSyncReport);
  Old := Length(FSlots);
  if FDoc.SlotCount > Old then
  begin
    SetLength(FSlots, FDoc.SlotCount);
    for S := Old to FDoc.SlotCount - 1 do
      FSlots[S] := Default(TCADViewSlotState);
  end;
  for S := 0 to Length(FSlots) - 1 do
    SyncSlot(S, Result);
  if Result.Updated + Result.Shown + Result.Hidden + Result.Failed > 0 then
    FTarget.Changed;
  Result.Milliseconds := GetTickCount64 - T0;
end;

end.
