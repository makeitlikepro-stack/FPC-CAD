unit CAD.Core.History;
{$mode objfpc}{$H+}

{ ROLE:      Undo/Redo stacks of commands for one document.
  CALLED BY: UI actions, scripts, tests.
  CALLS:     TCADCommand.DoIt/UndoIt/TryMerge.
  THREADS:   UI thread only.
  SPEED:     merging keeps a drag of hundreds of steps as one entry; the
             depth limit keeps memory bounded. Recompute is NOT called here:
             the caller recomputes once after a batch of edits. }

interface

uses
  Contnrs, SysUtils, CAD.Core.Document, CAD.Core.Commands;

type
  TCADHistory = class
  private
    FDoc: TCADDocument;
    FUndo, FRedo: TObjectList;     { own their commands }
    FMaxDepth: Integer;
    function GetCanUndo: Boolean;
    function GetCanRedo: Boolean;
  public
    constructor Create(ADoc: TCADDocument; AMaxDepth: Integer = 500);
    destructor Destroy; override;
    { Takes ownership of ACommand in every case. AMergeWithPrevious: try to
      fold it into the last command (continuous edits such as a drag).
      Returns False when the command changed nothing (it is freed). }
    function Execute(ACommand: TCADCommand; AMergeWithPrevious: Boolean = False): Boolean;
    function Undo: Boolean;
    function Redo: Boolean;
    procedure Clear;
    function UndoDescription: string;
    property CanUndo: Boolean read GetCanUndo;
    property CanRedo: Boolean read GetCanRedo;
  end;

implementation

constructor TCADHistory.Create(ADoc: TCADDocument; AMaxDepth: Integer);
begin
  inherited Create;
  FDoc := ADoc;
  FUndo := TObjectList.Create(True);
  FRedo := TObjectList.Create(True);
  FMaxDepth := AMaxDepth;
end;

destructor TCADHistory.Destroy;
begin
  { Free before the document: commands may own detached features. }
  FRedo.Free;
  FUndo.Free;
  inherited Destroy;
end;

function TCADHistory.GetCanUndo: Boolean;
begin
  Result := FUndo.Count > 0;
end;

function TCADHistory.GetCanRedo: Boolean;
begin
  Result := FRedo.Count > 0;
end;

function TCADHistory.Execute(ACommand: TCADCommand; AMergeWithPrevious: Boolean): Boolean;
var
  Last: TCADCommand;
begin
  Result := ACommand.DoIt(FDoc);
  if not Result then
  begin
    ACommand.Free;
    Exit;
  end;
  FRedo.Clear;                        { a new edit ends the redo branch }
  if AMergeWithPrevious and (FUndo.Count > 0) then
  begin
    Last := TCADCommand(FUndo.Last);
    if Last.TryMerge(ACommand) then
    begin
      ACommand.Free;
      Exit;
    end;
  end;
  FUndo.Add(ACommand);
  while FUndo.Count > FMaxDepth do
    FUndo.Delete(0);                  { frees the oldest command }
end;

function TCADHistory.Undo: Boolean;
var
  C: TCADCommand;
begin
  Result := FUndo.Count > 0;
  if not Result then
    Exit;
  { Leave the command in Undo until UndoIt succeeds. In particular,
    a failed Body detach must not silently discard the only restore path. }
  C := TCADCommand(FUndo.Last);
  C.UndoIt(FDoc);
  FUndo.Extract(C);
  FRedo.Add(C);
end;

function TCADHistory.Redo: Boolean;
var
  C: TCADCommand;
begin
  Result := FRedo.Count > 0;
  if not Result then
    Exit;
  { A rejected Redo stays available. A failure must not destroy the
    command and its detached Feature before the user can repair context. }
  C := TCADCommand(FRedo.Last);
  Result := C.DoIt(FDoc);
  if Result then
  begin
    FRedo.Extract(C);
    FUndo.Add(C);
  end;
end;

procedure TCADHistory.Clear;
begin
  FRedo.Clear;
  FUndo.Clear;
end;

function TCADHistory.UndoDescription: string;
begin
  if FUndo.Count = 0 then
    Exit('');
  Result := TCADCommand(FUndo.Last).Description;
end;

end.
