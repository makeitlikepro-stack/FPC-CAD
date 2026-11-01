unit CAD.Core.ObjectModel;
{$mode objfpc}{$H+}

{ ROLE: Document-owned logical Part/Body/Sketch/Datum registry. Pure FPC;
  no LCL, OpenGL or OCCT handles. Object IDs do not alias feature IDs.
  Removed objects stay as tombstones for exact Undo/Redo restoration. }
interface

uses
  SysUtils, CAD.Core.ObjectIds;

type
  TCADDatumKind = (cdkXY, cdkXZ, cdkYZ, cdkCustom);
  TCADVector3 = array[0..2] of Double;

  TCADDatumFrame = record
    Origin, XDir, Normal: TCADVector3;
  end;

  TCADModelObject = class
  private
    FId, FPartId, FSupportId: TCADObjectId;
    FKind: TCADObjectKind;
    FName: string;
    FActive, FVisible, FIsDefault: Boolean;
    FDatumKind: TCADDatumKind;
    FFrame: TCADDatumFrame;
  public
    property Id: TCADObjectId read FId;
    property Kind: TCADObjectKind read FKind;
    property PartId: TCADObjectId read FPartId;
    property SupportId: TCADObjectId read FSupportId;
    property Name: string read FName;
    property Active: Boolean read FActive;
    property Visible: Boolean read FVisible;
    property IsDefault: Boolean read FIsDefault;
    property DatumKind: TCADDatumKind read FDatumKind;
    property Frame: TCADDatumFrame read FFrame;
  end;

  TCADObjectModel = class
  private
    FSlots: array of TCADModelObject;
    FCount: Integer;
    FNextId, FRevision: QWord;
    FPartId, FOriginId, FXYId, FXZId, FYZId: TCADObjectId;
    function FindId(const AId: TCADObjectId): TCADModelObject;
    function AddObject(AKind: TCADObjectKind; const APart,
      ASupport: TCADObjectId; const AName: string;
      ADefault: Boolean): TCADModelObject;
    function CheckActive(const ARef: TCADObjectRef;
      out AError: string): TCADModelObject;
    function CanRemove(AObject: TCADModelObject;
      out AError: string): Boolean;
    procedure InitDefaults;
  public
    constructor Create;
    destructor Destroy; override;
    { Typed lookup: an ID from another kind never resolves. Deleted IDs
      remain permanently invalid outside Restore. }
    function Find(const ARef: TCADObjectRef): TCADModelObject;
    function TryAddBody(const APart: TCADObjectRef; const AName: string;
      out AId: TCADObjectId; out AError: string): Boolean;
    function TryAddSketch(const APart, ASupport: TCADObjectRef;
      const AName: string; out AId: TCADObjectId;
      out AError: string): Boolean;
    function TryRemove(const ARef: TCADObjectRef;
      out AError: string): Boolean;
    function TryRestore(const ARef: TCADObjectRef;
      out AError: string): Boolean;
    function TryRename(const ARef: TCADObjectRef; const AName: string;
      out AError: string): Boolean;
    function TrySetVisible(const ARef: TCADObjectRef; AVisible: Boolean;
      out AError: string): Boolean;
    function ActiveCount(AKind: TCADObjectKind): Integer;
    property PartId: TCADObjectId read FPartId;
    property OriginId: TCADObjectId read FOriginId;
    property XYPlaneId: TCADObjectId read FXYId;
    property XZPlaneId: TCADObjectId read FXZId;
    property YZPlaneId: TCADObjectId read FYZId;
    property NextId: QWord read FNextId;
    property Revision: QWord read FRevision;
  end;

function CADDefaultDatumFrame(AKind: TCADDatumKind): TCADDatumFrame;

implementation

function CADDefaultDatumFrame(AKind: TCADDatumKind): TCADDatumFrame;
begin
  Result := Default(TCADDatumFrame);
  Result.XDir[0] := 1;
  case AKind of
    cdkXY: Result.Normal[2] := 1;
    cdkXZ: Result.Normal[1] := -1;
    cdkYZ:
      begin
        Result.XDir[0] := 0;
        Result.XDir[1] := 1;
        Result.Normal[0] := 1;
      end;
  else
    Result.Normal[2] := 1;
  end;
end;

constructor TCADObjectModel.Create;
begin
  inherited Create;
  FNextId := 1;
  InitDefaults;
end;

destructor TCADObjectModel.Destroy;
var
  I: Integer;
begin
  for I := 0 to FCount-1 do FSlots[I].Free;
  inherited Destroy;
end;

function TCADObjectModel.AddObject(AKind: TCADObjectKind;
  const APart, ASupport: TCADObjectId; const AName: string;
  ADefault: Boolean): TCADModelObject;
begin
  { The slot and the persistent ID have the same monotonically increasing
    order. Tombstones are never reused; direct lookup is O(1). }
  if FNextId > QWord(High(Integer)) then
    raise Exception.Create('CAD object ID table exhausted');
  if FCount >= Length(FSlots) then
    SetLength(FSlots, FCount*2+16);
  Result := TCADModelObject.Create;
  Result.FId := CADObjectId(FNextId);
  Result.FKind := AKind;
  Result.FPartId := APart;
  Result.FSupportId := ASupport;
  Result.FName := AName;
  Result.FActive := True;
  Result.FVisible := True;
  Result.FIsDefault := ADefault;
  FSlots[FCount] := Result;
  Inc(FCount);
  Inc(FNextId);
  Inc(FRevision);
end;

procedure TCADObjectModel.InitDefaults;
var
  O: TCADModelObject;
begin
  FPartId := AddObject(cokPart, CADNoObjectId,
    CADNoObjectId, 'Part001', True).Id;
  FOriginId := AddObject(cokOrigin, FPartId,
    CADNoObjectId, 'Origin', True).Id;
  O := AddObject(cokDatumPlane, FPartId, FOriginId,
    'XY Plane', True);
  O.FDatumKind := cdkXY;
  O.FFrame := CADDefaultDatumFrame(cdkXY);
  FXYId := O.Id;
  O := AddObject(cokDatumPlane, FPartId, FOriginId,
    'XZ Plane', True);
  O.FDatumKind := cdkXZ;
  O.FFrame := CADDefaultDatumFrame(cdkXZ);
  FXZId := O.Id;
  O := AddObject(cokDatumPlane, FPartId, FOriginId,
    'YZ Plane', True);
  O.FDatumKind := cdkYZ;
  O.FFrame := CADDefaultDatumFrame(cdkYZ);
  FYZId := O.Id;
end;

function TCADObjectModel.FindId(const AId: TCADObjectId): TCADModelObject;
var
  N: Integer;
begin
  Result := nil;
  if (AId.Value = 0) or (AId.Value > QWord(FCount)) then Exit;
  N := Integer(AId.Value)-1;
  Result := FSlots[N];
  if (Result = nil) or not Result.FActive then Result := nil;
end;

function TCADObjectModel.Find(const ARef: TCADObjectRef): TCADModelObject;
begin
  Result := FindId(ARef.Id);
  if (Result <> nil) and (Result.Kind <> ARef.Kind) then
    Result := nil;
end;

function TCADObjectModel.CheckActive(const ARef: TCADObjectRef;
  out AError: string): TCADModelObject;
begin
  Result := FindId(ARef.Id);
  AError := '';
  if Result = nil then
    AError := 'missing or deleted CAD object'
  else if Result.Kind <> ARef.Kind then
  begin
    AError := 'wrong CAD object kind';
    Result := nil;
  end;
end;

function TCADObjectModel.TryAddBody(const APart: TCADObjectRef;
  const AName: string; out AId: TCADObjectId;
  out AError: string): Boolean;
begin
  AId := CADNoObjectId;
  Result := CheckActive(APart,AError) <> nil;
  if not Result then Exit;
  if APart.Kind <> cokPart then
  begin
    AError := 'Body must belong to a Part';
    Exit(False);
  end;
  if Trim(AName) = '' then
  begin
    AError := 'Body name cannot be empty';
    Exit(False);
  end;
  AId := AddObject(cokBody, APart.Id, CADNoObjectId, AName, False).Id;
end;

function TCADObjectModel.TryAddSketch(const APart, ASupport: TCADObjectRef;
  const AName: string; out AId: TCADObjectId;
  out AError: string): Boolean;
var
  P, D: TCADModelObject;
begin
  AId := CADNoObjectId;
  P := CheckActive(APart,AError);
  if P = nil then Exit(False);
  if P.Kind <> cokPart then Exit(False);
  D := CheckActive(ASupport,AError);
  if D = nil then Exit(False);
  if D.Kind <> cokDatumPlane then
  begin
    AError := 'Sketch support must be a Datum plane';
    Exit(False);
  end;
  if not CADSameObjectId(D.PartId,P.Id) then
  begin
    AError := 'Sketch support belongs to another Part';
    Exit(False);
  end;
  if Trim(AName) = '' then
  begin
    AError := 'Sketch name cannot be empty';
    Exit(False);
  end;
  AId := AddObject(cokSketch,P.Id,D.Id,AName,False).Id;
  Result := True;
end;

function TCADObjectModel.CanRemove(AObject: TCADModelObject;
  out AError: string): Boolean;
var
  I: Integer;
  O: TCADModelObject;
begin
  AError := '';
  if AObject.FIsDefault then
  begin
    AError := 'Cannot remove a default Part, Origin or Datum';
    Exit(False);
  end;
  for I := 0 to FCount-1 do
  begin
    O := FSlots[I];
    if not O.Active or (O = AObject) then Continue;
    if CADSameObjectId(O.PartId,AObject.Id) or
       CADSameObjectId(O.SupportId,AObject.Id) then
    begin
      AError := 'CAD object is referenced by '+O.Name;
      Exit(False);
    end;
  end;
  Result := True;
end;

function TCADObjectModel.TryRemove(const ARef: TCADObjectRef;
  out AError: string): Boolean;
var O: TCADModelObject;
begin
  O := CheckActive(ARef,AError);
  Result := (O <> nil) and CanRemove(O,AError);
  if not Result then Exit;
  O.FActive := False;
  Inc(FRevision);
end;

function TCADObjectModel.TryRestore(const ARef: TCADObjectRef;
  out AError: string): Boolean;
var O, P, D: TCADModelObject;
begin
  AError := '';
  Result := False;
  if (ARef.Id.Value = 0) or (ARef.Id.Value > QWord(FCount)) then
  begin
    AError := 'unknown CAD object ID';
    Exit;
  end;
  O := FSlots[Integer(ARef.Id.Value)-1];
  if O.Kind <> ARef.Kind then
  begin
    AError := 'wrong CAD object kind';
    Exit;
  end;
  if O.Active then
  begin
    AError := 'CAD object is already active';
    Exit;
  end;
  P := FindId(O.PartId);
  if (O.Kind <> cokPart) and
     ((P = nil) or (P.Kind <> cokPart)) then
  begin
    AError := 'parent Part is not active';
    Exit;
  end;
  if O.Kind = cokSketch then
  begin
    D := FindId(O.SupportId);
    if (D = nil) or (D.Kind <> cokDatumPlane) or
       not CADSameObjectId(D.PartId,O.PartId) then
    begin
      AError := 'Sketch support Datum is not active';
      Exit;
    end;
  end;
  O.FActive := True;
  Inc(FRevision);
  Result := True;
end;

function TCADObjectModel.TryRename(const ARef: TCADObjectRef;
  const AName: string; out AError: string): Boolean;
var O: TCADModelObject;
begin
  O := CheckActive(ARef,AError);
  Result := O <> nil;
  if not Result then Exit;
  if O.IsDefault then
  begin
    AError := 'default CAD object cannot be renamed';
    Exit(False);
  end;
  if Trim(AName) = '' then
  begin
    AError := 'CAD object name cannot be empty';
    Exit(False);
  end;
  Result := O.Name <> AName;
  if Result then
  begin
    O.FName := AName;
    Inc(FRevision);
  end;
end;

function TCADObjectModel.TrySetVisible(const ARef: TCADObjectRef;
  AVisible: Boolean; out AError: string): Boolean;
var O: TCADModelObject;
begin
  O := CheckActive(ARef,AError);
  Result := O <> nil;
  if not Result then Exit;
  if not (O.Kind in [cokBody,cokSketch]) then
  begin
    AError := 'visibility can only be changed for Body or Sketch';
    Exit(False);
  end;
  Result := O.Visible <> AVisible;
  if Result then
  begin
    O.FVisible := AVisible;
    Inc(FRevision);
  end;
end;

function TCADObjectModel.ActiveCount(AKind: TCADObjectKind): Integer;
var I: Integer;
begin
  Result := 0;
  for I := 0 to FCount-1 do
    if FSlots[I].Active and (FSlots[I].Kind = AKind) then
      Inc(Result);
end;

end.
