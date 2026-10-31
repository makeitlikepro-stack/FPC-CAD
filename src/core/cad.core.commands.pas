unit CAD.Core.Commands;
{$mode objfpc}{$H+}

{ ROLE:      every edit of the document as an object that can do and undo
             itself (set parameter, add feature, remove feature, link).
  CALLED BY: TCADHistory (Execute / Undo / Redo).
  CALLS:     TCADDocument structure and parameter methods.
  THREADS:   UI thread, never during a recompute.
  SPEED:     a command stores only what changed (one value, one link, one
             detached feature), never a copy of the document. Undo then
             restores keys that the result cache still knows. }

interface

uses
  SysUtils, CAD.Core.Ids, CAD.Core.Values, CAD.Core.Feature, CAD.Core.Document;

type
  TCADCommand = class
  public
    { False = nothing changed; the history drops the command. }
    function DoIt(ADoc: TCADDocument): Boolean; virtual; abstract;
    procedure UndoIt(ADoc: TCADDocument); virtual; abstract;
    { Merge ANext into Self (e.g. many drag steps of one parameter become
      one undo step). Only asked when the caller allows merging. }
    function TryMerge(ANext: TCADCommand): Boolean; virtual;
    function Description: string; virtual;
  end;

  TCADSetParamCommand = class(TCADCommand)
  private
    FId: TCADId;
    FName: string;
    FOld, FNew: TCADValue;
  public
    constructor Create(const AId: TCADId; const AName: string; const AValue: TCADValue);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function TryMerge(ANext: TCADCommand): Boolean; override;
    function Description: string; override;
  end;

  { Adds a new feature with its inputs. Owns the feature while undone. }
  TCADAddFeatureCommand = class(TCADCommand)
  private
    FFeature: TCADFeature;
    FInputs: TCADIdArray;
    FOwnsFeature: Boolean;
    FAttachedOnce: Boolean;
    FId: TCADId;
  public
    constructor Create(AFeature: TCADFeature; const AInputs: array of TCADId);
    destructor Destroy; override;
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
    { Valid after the first DoIt. }
    property Id: TCADId read FId;
  end;

  { Removes a feature that nothing uses. Owns the feature while done. }
  TCADRemoveFeatureCommand = class(TCADCommand)
  private
    FId: TCADId;
    FFeature: TCADFeature;
  public
    constructor Create(const AId: TCADId);
    destructor Destroy; override;
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
  end;

  TCADLinkCommand = class(TCADCommand)
  private
    FUser, FInput: TCADId;
    FError: string;
  public
    constructor Create(const AUser, AInput: TCADId);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
    property Error: string read FError;
  end;

implementation

{ TCADCommand }

function TCADCommand.TryMerge(ANext: TCADCommand): Boolean;
begin
  Result := False;
end;

function TCADCommand.Description: string;
begin
  Result := ClassName;
end;

{ TCADSetParamCommand }

constructor TCADSetParamCommand.Create(const AId: TCADId; const AName: string;
  const AValue: TCADValue);
begin
  inherited Create;
  FId := AId;
  FName := AName;
  FNew := AValue;
end;

function TCADSetParamCommand.DoIt(ADoc: TCADDocument): Boolean;
var
  F: TCADFeature;
begin
  F := ADoc.Find(FId);
  Result := F <> nil;
  if not Result then
    Exit;
  FOld := F.GetParamValue(FName);
  Result := (FOld.Kind = FNew.Kind) and (not CADValueEqual(FOld, FNew)) and
    ADoc.SetParam(FId, FName, FNew);
end;

procedure TCADSetParamCommand.UndoIt(ADoc: TCADDocument);
begin
  ADoc.SetParam(FId, FName, FOld);
end;

function TCADSetParamCommand.TryMerge(ANext: TCADCommand): Boolean;
var
  N: TCADSetParamCommand;
begin
  Result := (ANext is TCADSetParamCommand);
  if not Result then
    Exit;
  N := TCADSetParamCommand(ANext);
  Result := CADIdEqual(N.FId, FId) and SameText(N.FName, FName);
  if Result then
    FNew := N.FNew;                    { keep the oldest FOld: one undo step }
end;

function TCADSetParamCommand.Description: string;
begin
  Result := Format('Set %s = %s', [FName, CADValueToString(FNew)]);
end;

{ TCADAddFeatureCommand }

constructor TCADAddFeatureCommand.Create(AFeature: TCADFeature; const AInputs: array of TCADId);
var
  I: Integer;
begin
  inherited Create;
  FFeature := AFeature;
  FOwnsFeature := True;
  FId := CADNoId;
  SetLength(FInputs, Length(AInputs));
  for I := 0 to High(AInputs) do
    FInputs[I] := AInputs[I];
end;

destructor TCADAddFeatureCommand.Destroy;
begin
  if FOwnsFeature then
    FFeature.Free;
  inherited Destroy;
end;

function TCADAddFeatureCommand.DoIt(ADoc: TCADDocument): Boolean;
var
  I: Integer;
  Err: string;
begin
  if not FAttachedOnce then
  begin
    FId := ADoc.AttachFeature(FFeature);
    FOwnsFeature := False;
    FAttachedOnce := True;
    for I := 0 to High(FInputs) do
      if not ADoc.TryLink(FId, FInputs[I], Err) then
      begin
        { Roll back: the document gives the feature back to us. }
        ADoc.DetachFeature(FId);
        FOwnsFeature := True;
        FAttachedOnce := False;
        Exit(False);
      end;
    Exit(True);
  end;
  { Redo: same id, inputs are stored on the detached feature. }
  Result := ADoc.ReattachFeature(FFeature);
  if Result then
    FOwnsFeature := False;
end;

procedure TCADAddFeatureCommand.UndoIt(ADoc: TCADDocument);
begin
  if ADoc.DetachFeature(FId) <> nil then
    FOwnsFeature := True;
end;

function TCADAddFeatureCommand.Description: string;
begin
  Result := 'Add ' + FFeature.TypeName;
end;

{ TCADRemoveFeatureCommand }

constructor TCADRemoveFeatureCommand.Create(const AId: TCADId);
begin
  inherited Create;
  FId := AId;
end;

destructor TCADRemoveFeatureCommand.Destroy;
begin
  FFeature.Free;                       { non-nil only while removed }
  inherited Destroy;
end;

function TCADRemoveFeatureCommand.DoIt(ADoc: TCADDocument): Boolean;
begin
  FFeature := ADoc.DetachFeature(FId);
  Result := FFeature <> nil;
end;

procedure TCADRemoveFeatureCommand.UndoIt(ADoc: TCADDocument);
begin
  if (FFeature <> nil) and ADoc.ReattachFeature(FFeature) then
    FFeature := nil;                   { the document owns it again }
end;

function TCADRemoveFeatureCommand.Description: string;
begin
  Result := 'Remove feature';
end;

{ TCADLinkCommand }

constructor TCADLinkCommand.Create(const AUser, AInput: TCADId);
begin
  inherited Create;
  FUser := AUser;
  FInput := AInput;
end;

function TCADLinkCommand.DoIt(ADoc: TCADDocument): Boolean;
begin
  Result := ADoc.TryLink(FUser, FInput, FError);
end;

procedure TCADLinkCommand.UndoIt(ADoc: TCADDocument);
begin
  ADoc.Unlink(FUser, FInput);
end;

function TCADLinkCommand.Description: string;
begin
  Result := 'Link';
end;

end.
