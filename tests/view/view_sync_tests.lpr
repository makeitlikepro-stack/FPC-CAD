program view_sync_tests;
{$mode objfpc}{$H+}

{ Tests of CAD.View.Sync with a fake viewport and fake results (no OCCT, no GL).
  Run: bash scripts/test_view.sh
  Document: A = Const(1), B = Const(2), C = Sum(A, B). Only chain ends are
  shown (csmAuto), so the first sync draws C only. Then: nothing changed,
  parameter change, csmShow mid-tree, hide/show without converting, filler
  failure and retry, detach, id mapping. }

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, CAD.Core.Ids, CAD.Core.Values, CAD.Core.Feature, CAD.Core.Document,
  CAD.View.Sync, OpenGL.UI.Viewport3D.Camera, OpenGL.Render.Viewport3DMeshData;

var
  Checks, Failures: Integer;
  FillCalls: Integer = 0;
  FailFill: Boolean = False;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(Checks);
  if not ACondition then
  begin
    Inc(Failures);
    WriteLn('FAIL  ', AName);
  end;
end;

{ ---------------------------------------------------------------- fakes }

type
  TNumResult = class(TCADResult)
  public
    Value: Double;
    Meshed: Boolean;
    function DisplayReady: Boolean; override;
    function PrepareDisplay(out AError: string): Boolean; override;
  end;

  TConstFeature = class(TCADFeature)
  protected
    procedure DefineParams; override;
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

  TSumFeature = class(TCADFeature)
  protected
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

  TFakeObject = class
  public
    Mesh: TV3DMeshData;
    Visible: Boolean;
    destructor Destroy; override;
  end;

  TFakeTarget = class(TCADViewTarget)
  public
    Objects: array[0..15] of TFakeObject;
    ChangedCalls: Integer;
    destructor Destroy; override;
    function MeshFor(AObjectId: Cardinal): TV3DMeshData; override;
    procedure SetObjectVisible(AObjectId: Cardinal; AVisible: Boolean); override;
    procedure Changed; override;
    function Has(AObjectId: Cardinal): Boolean;
    function IsVisible(AObjectId: Cardinal): Boolean;
    function ValueOf(AObjectId: Cardinal): Double;
  end;

function TNumResult.DisplayReady: Boolean;
begin
  Result := Meshed;
end;

function TNumResult.PrepareDisplay(out AError: string): Boolean;
begin
  AError := '';
  Meshed := True;
  Result := True;
end;

class function TConstFeature.TypeName: string;
begin
  Result := 'Const';
end;

procedure TConstFeature.DefineParams;
begin
  AddParam('value', CADFloat(0));
end;

function TConstFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
var
  R: TNumResult;
begin
  AError := '';
  R := TNumResult.Create;
  R.Value := GetParamValue('value').F;
  AResult := R;
  Result := True;
end;

class function TSumFeature.TypeName: string;
begin
  Result := 'Sum';
end;

function TSumFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
var
  R: TNumResult;
  I: Integer;
begin
  AError := '';
  R := TNumResult.Create;
  R.Value := 0;
  for I := 0 to High(AInputs) do
    R.Value := R.Value + TNumResult(AInputs[I]).Value;
  AResult := R;
  Result := True;
end;

destructor TFakeObject.Destroy;
begin
  Mesh.Free;
  inherited Destroy;
end;

destructor TFakeTarget.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Objects) do
    Objects[I].Free;
  inherited Destroy;
end;

function TFakeTarget.MeshFor(AObjectId: Cardinal): TV3DMeshData;
begin
  if Objects[AObjectId] = nil then
  begin
    Objects[AObjectId] := TFakeObject.Create;
    Objects[AObjectId].Mesh := TV3DMeshData.Create;
  end;
  Result := Objects[AObjectId].Mesh;
end;

procedure TFakeTarget.SetObjectVisible(AObjectId: Cardinal; AVisible: Boolean);
begin
  if Objects[AObjectId] <> nil then
    Objects[AObjectId].Visible := AVisible;
end;

procedure TFakeTarget.Changed;
begin
  Inc(ChangedCalls);
end;

function TFakeTarget.Has(AObjectId: Cardinal): Boolean;
begin
  Result := Objects[AObjectId] <> nil;
end;

function TFakeTarget.IsVisible(AObjectId: Cardinal): Boolean;
begin
  Result := Has(AObjectId) and Objects[AObjectId].Visible;
end;

{ The fake filler writes one vertex whose X is the result value. }
function TFakeTarget.ValueOf(AObjectId: Cardinal): Double;
begin
  Result := -1;
  if Has(AObjectId) and (Objects[AObjectId].Mesh.VertexCount = 1) then
    Result := Objects[AObjectId].Mesh.Vertices[0].PX;
end;

function FakeFill(AResult: TCADResult; AMesh: TV3DMeshData; out AError: string): Boolean;
begin
  Inc(FillCalls);
  AMesh.Clear;
  AError := '';
  if FailFill then
  begin
    AError := 'fake failure';
    Exit(False);
  end;
  AMesh.AddVertex(V3(TNumResult(AResult).Value, 0, 0), V3(0, 0, 1), 1);
  Result := True;
end;

{ ---------------------------------------------------------------- helpers }

function NewConst(AValue: Double): TConstFeature;
begin
  Result := TConstFeature.Create;
  Result.SetParamValue('value', CADFloat(AValue));
end;

function SameReport(const R: TCADViewSyncReport; AUpd, AShown, AHid, AUnch, AFail: Integer): Boolean;
begin
  Result := (R.Updated = AUpd) and (R.Shown = AShown) and (R.Hidden = AHid) and
    (R.Unchanged = AUnch) and (R.Failed = AFail);
end;

function Fmt(const R: TCADViewSyncReport): string;
begin
  Result := Format('upd %d shown %d hid %d unch %d fail %d',
    [R.Updated, R.Shown, R.Hidden, R.Unchanged, R.Failed]);
end;

{ ---------------------------------------------------------------- test }

procedure TestSync;
var
  Doc: TCADDocument;
  T: TFakeTarget;
  S: TCADViewSync;
  A, B, C: TCADId;
  OA, OB, OC: Cardinal;
  R: TCADViewSyncReport;
  Err: string;
  Fills: Integer;
  Detached: TCADFeature;
begin
  Doc := TCADDocument.Create;
  T := TFakeTarget.Create;
  S := TCADViewSync.Create(Doc, T, @FakeFill);
  try
    A := Doc.AttachFeature(NewConst(1));
    B := Doc.AttachFeature(NewConst(2));
    C := Doc.AttachFeature(TSumFeature.Create);
    Check(Doc.TryLink(C, A, Err) and Doc.TryLink(C, B, Err), 'links: ' + Err);
    OA := TCADViewSync.ObjectIdOf(A);
    OB := TCADViewSync.ObjectIdOf(B);
    OC := TCADViewSync.ObjectIdOf(C);
    Check((OA = 1) and (OB = 2) and (OC = 3), 'object id = slot + 1');
    Check(CADIdEqual(TCADViewSync.FeatureOf(OC), C) and
      not CADIdValid(TCADViewSync.FeatureOf(0)), 'FeatureOf maps back, 0 = none');

    Doc.Recompute;
    R := S.Sync;
    Check(SameReport(R, 1, 0, 0, 0, 0), 'first sync: only C converted (' + Fmt(R) + ')');
    Check(T.IsVisible(OC) and (T.ValueOf(OC) = 3), 'C drawn with value 3');
    Check(not T.Has(OA) and not T.Has(OB), 'inputs A, B get no object');
    Check(T.ChangedCalls = 1, 'one redraw request');

    R := S.Sync;
    Check(SameReport(R, 0, 0, 0, 1, 0) and (T.ChangedCalls = 1), 'second sync: nothing to do, no redraw');

    Doc.SetParam(A, 'value', CADFloat(5));
    Doc.Recompute;
    R := S.Sync;
    Check(SameReport(R, 1, 0, 0, 0, 0) and (T.ValueOf(OC) = 7), 'param change: C reconverted to 7 (' + Fmt(R) + ')');

    Doc.SetShowMode(A, csmShow);
    Doc.Recompute;
    R := S.Sync;
    Check(SameReport(R, 1, 0, 0, 1, 0) and T.IsVisible(OA) and (T.ValueOf(OA) = 5),
      'csmShow mid-tree: A converted, C unchanged (' + Fmt(R) + ')');

    Fills := FillCalls;
    Doc.SetShowMode(A, csmHide);
    Doc.Recompute;
    R := S.Sync;
    Check(SameReport(R, 0, 0, 1, 1, 0) and not T.IsVisible(OA), 'csmHide: A hidden (' + Fmt(R) + ')');
    Doc.SetShowMode(A, csmShow);
    Doc.Recompute;
    R := S.Sync;
    Check(SameReport(R, 0, 1, 0, 1, 0) and T.IsVisible(OA) and (FillCalls = Fills),
      'show again: visible without converting (' + Fmt(R) + ')');

    FailFill := True;
    Doc.SetParam(B, 'value', CADFloat(10));
    Doc.Recompute;
    R := S.Sync;
    Check((R.Failed = 1) and not T.IsVisible(OC) and (Pos('fake failure', S.LastError) > 0),
      'filler failure: C hidden, error kept (' + Fmt(R) + ')');
    FailFill := False;
    R := S.Sync;
    Check((R.Updated = 1) and T.IsVisible(OC) and (T.ValueOf(OC) = 15),
      'next sync retries without a recompute (' + Fmt(R) + ')');

    Detached := Doc.DetachFeature(C);
    Doc.Recompute;
    R := S.Sync;
    Check(not T.IsVisible(OC), 'detached C hidden (' + Fmt(R) + ')');
    Check(T.IsVisible(OA), 'A still shown (csmShow)');
    Detached.Free;

    S.Reset;
    T.Objects[OA].Visible := False;
    R := S.Sync;
    Check(T.IsVisible(OA) and (R.Updated >= 1), 'after Reset everything shown is converted again');
  finally
    S.Free;
    T.Free;
    Doc.Free;
  end;
end;

begin
  Checks := 0;
  Failures := 0;
  TestSync;
  if Failures = 0 then
    WriteLn(Format('PASS  view sync: %d checks', [Checks]))
  else
    WriteLn(Format('FAIL  view sync: %d of %d checks failed', [Failures, Checks]));
  if Failures <> 0 then
    Halt(1);
end.
