unit CAD.App.DesignLookup;
{$mode objfpc}{$H+}
{$codepage utf8}

{ ROLE:      finds the widgets of the IDE-designed main window by id, so the
             application classes bind to the design instead of building
             widgets (app/MainForm.fvform).
  CALLED BY: CAD.App.Controller, CAD.App.SketchToolbar, CAD.App.SketchPanel.
  CALLS:     the form's Widget(id) (TUIForm).
  THREADS:   UI thread.
  SPEED:     lookups only when the window starts. }

interface

uses
  SysUtils, OpenGL.ECS.Widgets;

type
  { TUIForm.Widget }
  TCADWidgetLookup = function(const AId: string): TUIWidget of object;
  ECADDesignError = class(Exception);

{ The widget AId of class AClass; raises a clear error when the design has
  none (renamed or deleted in the IDE). }
function CADDesignWidget(ALookup: TCADWidgetLookup; const AId: string;
  AClass: TClass): TUIWidget;

implementation

function CADDesignWidget(ALookup: TCADWidgetLookup; const AId: string;
  AClass: TClass): TUIWidget;
begin
  Result := ALookup(AId);
  if Result = nil then
    raise ECADDesignError.CreateFmt('app/MainForm.fvform has no widget "%s" (renamed or deleted?)', [AId]);
  if not Result.InheritsFrom(AClass) then
    raise ECADDesignError.CreateFmt('widget "%s" in app/MainForm.fvform must be a %s, not a %s',
      [AId, AClass.ClassName, Result.ClassName]);
end;

end.
