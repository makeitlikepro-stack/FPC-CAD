unit CAD.Core.BodyTipCommands;
{$mode objfpc}{$H+}

{ Body tip edits use the existing CAD history. Shape results stay in the
  result cache; this command only changes a typed Feature ID. }
interface

uses
  SysUtils, CAD.Core.Ids, CAD.Core.ObjectIds, CAD.Core.ObjectModel,
  CAD.Core.Document, CAD.Core.Commands;

type
  TCADSetBodyTipCommand = class(TCADCommand)
  private
    FBody: TCADObjectRef;
    FNewTip, FOldTip: TCADId;
    FCaptured: Boolean;
  public
    constructor Create(const ABody: TCADObjectRef; const ANewTip: TCADId);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
  end;

implementation

constructor TCADSetBodyTipCommand.Create(const ABody: TCADObjectRef;
  const ANewTip: TCADId);
begin
  inherited Create;
  FBody := ABody;
  FNewTip := ANewTip;
  FOldTip := CADNoId;
end;

function TCADSetBodyTipCommand.DoIt(ADoc: TCADDocument): Boolean;
var
  O: TCADModelObject;
  E: string;
begin
  O := ADoc.Objects.Find(FBody);
  if (O = nil) or (O.Kind <> cokBody) then Exit(False);
  if not FCaptured then FOldTip := O.TipFeatureId;
  Result := ADoc.TrySetBodyTip(FBody, FNewTip, E);
  if Result then FCaptured := True;
end;

procedure TCADSetBodyTipCommand.UndoIt(ADoc: TCADDocument);
var E: string;
begin
  if not ADoc.TrySetBodyTip(FBody, FOldTip, E) then
    raise Exception.Create('Undo Body tip: '+E);
end;

function TCADSetBodyTipCommand.Description: string;
begin
  Result := 'Change Body tip';
end;

end.
