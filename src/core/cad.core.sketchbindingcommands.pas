unit CAD.Core.SketchBindingCommands;
{$mode objfpc}{$H+}

{ One logical Sketch object references one existing Sketch evaluator Feature.
  This command changes only the binding; it never copies sketch geometry. }
interface

uses
  SysUtils, CAD.Core.Ids, CAD.Core.ObjectIds, CAD.Core.ObjectModel,
  CAD.Core.Document, CAD.Core.Commands;

type
  TCADBindSketchFeatureCommand = class(TCADCommand)
  private
    FSketch: TCADObjectRef;
    FNewFeature, FPreviousFeature: TCADId;
    FCaptured: Boolean;
  public
    constructor Create(const ASketch: TCADObjectRef; const AFeature: TCADId);
    function DoIt(ADoc: TCADDocument): Boolean; override;
    procedure UndoIt(ADoc: TCADDocument); override;
    function Description: string; override;
  end;

implementation

constructor TCADBindSketchFeatureCommand.Create(const ASketch: TCADObjectRef;
  const AFeature: TCADId);
begin
  inherited Create;
  FSketch := ASketch;
  FNewFeature := AFeature;
  FPreviousFeature := CADNoId;
end;

function TCADBindSketchFeatureCommand.DoIt(ADoc: TCADDocument): Boolean;
var
  O: TCADModelObject;
  E: string;
begin
  O := ADoc.Objects.Find(FSketch);
  if (O = nil) or (O.Kind <> cokSketch) then Exit(False);
  if FCaptured and not CADIdEqual(O.SketchFeatureId,FPreviousFeature) then
    Exit(False);
  if not FCaptured then FPreviousFeature := O.SketchFeatureId;
  Result := ADoc.TryBindSketchFeature(FSketch,FNewFeature,E);
  if Result then FCaptured := True;
end;

procedure TCADBindSketchFeatureCommand.UndoIt(ADoc: TCADDocument);
var
  O: TCADModelObject;
  E: string;
begin
  O := ADoc.Objects.Find(FSketch);
  if (O = nil) or not CADIdEqual(O.SketchFeatureId,FNewFeature) then
    raise Exception.Create('Undo Sketch binding: binding changed');
  if not ADoc.TryBindSketchFeature(FSketch,FPreviousFeature,E) then
    raise Exception.Create('Undo Sketch binding: '+E);
end;

function TCADBindSketchFeatureCommand.Description: string;
begin
  Result := 'Bind Sketch evaluator';
end;

end.
