unit CAD.View.ViewportTarget;
{$mode objfpc}{$H+}

{ ROLE:      TCADViewTarget on the engine TUIViewport3D (the real viewport
             for CAD.View.Sync).
  CALLED BY: the application (stage 4 step 3).
  CALLS:     OpenGL.UI.Viewport3D (FindObject, AddObject, Invalidate3D).
  THREADS:   UI thread only.
  SPEED:     FindObject per call; the viewport uploads a mesh to the GPU only
             when its Revision changed.
  Note:      the engine has no RemoveObject yet, so a removed feature keeps
             a hidden object (its mesh is kept for a cheap re-show). }

interface

uses
  CAD.View.Sync, OpenGL.UI.Viewport3D, OpenGL.Render.Viewport3DMeshData;

type
  TCADViewportTarget = class(TCADViewTarget)
  private
    FView: TUIViewport3D;
    FMaterial: string;
  public
    { AMaterial '' = the viewport default (phong). }
    constructor Create(AView: TUIViewport3D; const AMaterial: string = '');
    function MeshFor(AObjectId: Cardinal): TV3DMeshData; override;
    procedure SetObjectVisible(AObjectId: Cardinal; AVisible: Boolean); override;
    procedure Changed; override;
    property View: TUIViewport3D read FView;
  end;

implementation

constructor TCADViewportTarget.Create(AView: TUIViewport3D; const AMaterial: string);
begin
  inherited Create;
  FView := AView;
  FMaterial := AMaterial;
end;

function TCADViewportTarget.MeshFor(AObjectId: Cardinal): TV3DMeshData;
var
  O: TViewport3DObject;
begin
  O := FView.FindObject(AObjectId);
  if O = nil then
  begin
    O := FView.AddObject(TV3DMeshData.Create, FMaterial, AObjectId);
    O.Visible := False;           { the sync shows it after a good fill }
  end;
  Result := O.Mesh;
end;

procedure TCADViewportTarget.SetObjectVisible(AObjectId: Cardinal; AVisible: Boolean);
var
  O: TViewport3DObject;
begin
  O := FView.FindObject(AObjectId);
  if O <> nil then
    O.Visible := AVisible;
end;

procedure TCADViewportTarget.Changed;
begin
  FView.Invalidate3D;
end;

end.
