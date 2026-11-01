unit CAD.Core.ObjectCommands;
{$mode objfpc}{$H+}

{ Headless logical-object edits using the EXISTING TCADHistory command stack.
  No parallel Undo system. One change is atomic in TCADObjectModel; a failed
  command is not added to History. Redo revives the same tombstone ID. }
interface

uses
  SysUtils, CAD.Core.Commands, CAD.Core.Document, CAD.Core.ObjectIds;

type
  TCADCreateBodyCommand = class(TCADCommand)
  private
    FPart: TCADObjectRef;
    FName: string;
    FId: TCADObjectId;
  public
    constructor Create(const APart: TCADObjectRef; const AName: string);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
    property Id: TCADObjectId read FId;
  end;

  TCADCreateSketchCommand = class(TCADCommand)
  private
    FPart, FSupport: TCADObjectRef;
    FName: string;
    FId: TCADObjectId;
  public
    constructor Create(const APart, ASupport: TCADObjectRef;
      const AName: string);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
    property Id: TCADObjectId read FId;
  end;

  TCADRemoveObjectCommand = class(TCADCommand)
  private
    FRef: TCADObjectRef;
  public
    constructor Create(const ARef: TCADObjectRef);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
  end;

  TCADRenameObjectCommand = class(TCADCommand)
  private
    FRef: TCADObjectRef;
    FNew, FPrevious: string;
    FCaptured: Boolean;
  public
    constructor Create(const ARef: TCADObjectRef; const AName: string);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
  end;

  TCADShowObjectCommand = class(TCADCommand)
  private
    FRef: TCADObjectRef;
    FNew, FPrevious: Boolean;
    FCaptured: Boolean;
  public
    constructor Create(const ARef: TCADObjectRef; AVisible: Boolean);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
  end;

implementation

constructor TCADCreateBodyCommand.Create(const APart: TCADObjectRef;
  const AName: string);
begin
  inherited Create;
  FPart := APart;
  FName := AName;
  FId := CADNoObjectId;
end;

function TCADCreateBodyCommand.DoIt(ADoc: TCADDocument): Boolean;
var E: string;
begin
  if not CADObjectIdValid(FId) then
    Result := ADoc.Objects.TryAddBody(FPart,FName,FId,E)
  else
    Result := ADoc.Objects.TryRestore(CADObjectRef(cokBody,FId),E);
end;

procedure TCADCreateBodyCommand.UndoIt(ADoc: TCADDocument);
var E: string;
begin
  if not ADoc.Objects.TryRemove(CADObjectRef(cokBody,FId),E) then
    raise Exception.Create('Undo Create Body: '+E);
end;

function TCADCreateBodyCommand.Description: string;
begin
  Result := 'Create Body '+FName;
end;

constructor TCADCreateSketchCommand.Create(const APart, ASupport: TCADObjectRef;
  const AName: string);
begin
  inherited Create;
  FPart := APart;
  FSupport := ASupport;
  FName := AName;
  FId := CADNoObjectId;
end;

function TCADCreateSketchCommand.DoIt(ADoc: TCADDocument): Boolean;
var E: string;
begin
  if not CADObjectIdValid(FId) then
    Result := ADoc.Objects.TryAddSketch(FPart,FSupport,FName,FId,E)
  else
    Result := ADoc.Objects.TryRestore(CADObjectRef(cokSketch,FId),E);
end;

procedure TCADCreateSketchCommand.UndoIt(ADoc: TCADDocument);
var E: string;
begin
  if not ADoc.Objects.TryRemove(CADObjectRef(cokSketch,FId),E) then
    raise Exception.Create('Undo Create Sketch: '+E);
end;

function TCADCreateSketchCommand.Description: string;
begin
  Result := 'Create Sketch '+FName;
end;

constructor TCADRemoveObjectCommand.Create(const ARef: TCADObjectRef);
begin
  inherited Create;
  FRef := ARef;
end;

function TCADRemoveObjectCommand.DoIt(ADoc: TCADDocument): Boolean;
var E: string;
begin
  Result := ADoc.Objects.TryRemove(FRef,E);
end;

procedure TCADRemoveObjectCommand.UndoIt(ADoc: TCADDocument);
var E: string;
begin
  if not ADoc.Objects.TryRestore(FRef,E) then
    raise Exception.Create('Undo Remove CAD object: '+E);
end;

function TCADRemoveObjectCommand.Description: string;
begin
  Result := 'Remove CAD object';
end;

constructor TCADRenameObjectCommand.Create(const ARef: TCADObjectRef;
  const AName: string);
begin
  inherited Create;
  FRef := ARef;
  FNew := AName;
end;

function TCADRenameObjectCommand.DoIt(ADoc: TCADDocument): Boolean;
var
  E: string;
begin
  if ADoc.Objects.Find(FRef) = nil then Exit(False);
  if not FCaptured then
    FPrevious := ADoc.Objects.Find(FRef).Name;
  Result := ADoc.Objects.TryRename(FRef,FNew,E);
  if Result then FCaptured := True;
end;

procedure TCADRenameObjectCommand.UndoIt(ADoc: TCADDocument);
var E: string;
begin
  if not ADoc.Objects.TryRename(FRef,FPrevious,E) then
    raise Exception.Create('Undo Rename CAD object: '+E);
end;

function TCADRenameObjectCommand.Description: string;
begin
  Result := 'Rename CAD object';
end;

constructor TCADShowObjectCommand.Create(const ARef: TCADObjectRef;
  AVisible: Boolean);
begin
  inherited Create;
  FRef := ARef;
  FNew := AVisible;
end;

function TCADShowObjectCommand.DoIt(ADoc: TCADDocument): Boolean;
var E: string;
begin
  if ADoc.Objects.Find(FRef) = nil then Exit(False);
  if not FCaptured then
    FPrevious := ADoc.Objects.Find(FRef).Visible;
  Result := ADoc.Objects.TrySetVisible(FRef,FNew,E);
  if Result then FCaptured := True;
end;

procedure TCADShowObjectCommand.UndoIt(ADoc: TCADDocument);
var E: string;
begin
  if not ADoc.Objects.TrySetVisible(FRef,FPrevious,E) then
    raise Exception.Create('Undo CAD object visibility: '+E);
end;

function TCADShowObjectCommand.Description: string;
begin
  Result := 'Set CAD object visibility';
end;

end.
