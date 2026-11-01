unit CAD.Core.BodyFeatureCommands;
{$mode objfpc}{$H+}

{ A single history entry creates/links a Feature and advances one Body.
  Feature geometry stays owned by Document/ResultCache, never by the Body. }
interface

uses
  SysUtils, CAD.Core.Ids, CAD.Core.Feature, CAD.Core.ObjectIds,
  CAD.Core.ObjectModel, CAD.Core.Document, CAD.Core.Commands;

type
  TCADAddBodyFeatureCommand = class(TCADCommand)
  private
    FBody: TCADObjectRef;
    FFeature: TCADFeature;
    FInputs: TCADIdArray;
    FId, FPreviousTip: TCADId;
    FOwnsFeature, FAttachedOnce, FCaptured: Boolean;
    function Validate(ADoc: TCADDocument): Boolean;
  public
    constructor Create(const ABody: TCADObjectRef; AFeature: TCADFeature;
      const AInputs: array of TCADId);
    destructor Destroy; override;
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
    property Id: TCADId read FId;
  end;

implementation

constructor TCADAddBodyFeatureCommand.Create(const ABody: TCADObjectRef;
  AFeature: TCADFeature; const AInputs: array of TCADId);
var
  I: Integer;
begin
  inherited Create;
  FBody := ABody;
  FFeature := AFeature;
  FOwnsFeature := True;
  FId := CADNoId;
  FPreviousTip := CADNoId;
  SetLength(FInputs,Length(AInputs));
  for I := 0 to High(AInputs) do FInputs[I] := AInputs[I];
end;

destructor TCADAddBodyFeatureCommand.Destroy;
begin
  if FOwnsFeature then FFeature.Free;
  inherited Destroy;
end;

function TCADAddBodyFeatureCommand.Validate(ADoc: TCADDocument): Boolean;
var
  O: TCADModelObject;
  I, J: Integer;
  FoundPrevious: Boolean;
begin
  Result := False;
  O := ADoc.Objects.Find(FBody);
  if (O = nil) or (O.Kind <> cokBody) or (FFeature = nil) then Exit;
  if FCaptured and not CADIdEqual(O.TipFeatureId,FPreviousTip) then Exit;
  FoundPrevious := not CADIdValid(O.TipFeatureId);
  for I := 0 to High(FInputs) do
  begin
    if ADoc.Find(FInputs[I]) = nil then Exit;
    if CADIdEqual(FInputs[I],O.TipFeatureId) then FoundPrevious := True;
    for J := 0 to I-1 do
      if CADIdEqual(FInputs[I],FInputs[J]) then Exit;
  end;
  { A modifying operation must consume the current tip. The initial
    operation can consume profiles or other external evaluator features. }
  Result := FoundPrevious;
end;

function TCADAddBodyFeatureCommand.DoIt(ADoc: TCADDocument): Boolean;
var
  O: TCADModelObject;
  E: string;
  I: Integer;
  Detached: TCADFeature;
begin
  Result := False;
  if not Validate(ADoc) then Exit;
  O := ADoc.Objects.Find(FBody);
  if not FCaptured then FPreviousTip := O.TipFeatureId;
  if not FAttachedOnce then
  begin
    FId := ADoc.AttachFeature(FFeature);
    FAttachedOnce := True;
  end
  else if not ADoc.ReattachFeature(FFeature) then Exit;
  FOwnsFeature := False;

  try
    if not FCaptured then
      for I := 0 to High(FInputs) do
        if not ADoc.TryLink(FId,FInputs[I],E) then
          raise Exception.Create('Cannot link Body feature: '+E);
    if not ADoc.TrySetBodyTip(FBody,FId,E) then
      raise Exception.Create('Cannot advance Body tip: '+E);
    FCaptured := True;
    Result := True;
  except
    { Preflight prevents ordinary link failures; rollback remains necessary
      if a future graph constraint rejects an edit after attachment. }
    Detached := ADoc.DetachFeature(FId);
    if Detached = nil then
      raise Exception.Create('Body Feature rollback failed');
    FOwnsFeature := True;
    Result := False;
  end;
end;

procedure TCADAddBodyFeatureCommand.UndoIt(ADoc: TCADDocument);
var
  O: TCADModelObject;
  E: string;
  Detached: TCADFeature;
begin
  O := ADoc.Objects.Find(FBody);
  if (O = nil) or not CADIdEqual(O.TipFeatureId,FId) or
     (ADoc.UserCount(FId) <> 0) then
    raise Exception.Create('Cannot undo Body feature: tip changed or feature in use');
  if not ADoc.TrySetBodyTip(FBody,FPreviousTip,E) then
    raise Exception.Create('Cannot restore previous Body tip: '+E);
  Detached := ADoc.DetachFeature(FId);
  if Detached = nil then
  begin
    if not ADoc.TrySetBodyTip(FBody,FId,E) then
      raise Exception.Create('Cannot recover Body tip after detach failure: '+E);
    raise Exception.Create('Cannot detach Body feature during Undo');
  end;
  FOwnsFeature := True;
end;

function TCADAddBodyFeatureCommand.Description: string;
begin
  if FFeature = nil then Exit('Add Body feature');
  Result := 'Add Body '+FFeature.TypeName;
end;

end.
