unit CAD.App.ExtrudeGizmo;
{$mode objfpc}{$H+}

{ ROLE: Project and draw a depth grip on the actual 3D Extrude top face.
  Mouse displacement along the projected Sketch normal maps to true mm.
  Numeric input is positioned by the controller next to TipX/TipY.
  This unit has no document mutations or OCCT handles. }

interface

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.ContourSelection,
  CAD.Sketch.ExtrudeOptions, OpenGL.UI.Viewport3D.Camera,
  OpenGL.Render.Viewport3DMeshData;

type
  TCADExtrudeHandleFrame = record
    Base, Tip: TV3Vec;
    TipX, TipY: Double;              { coordinates local to Viewport3D }
    PixelsXPerMM, PixelsYPerMM: Double;
  end;

function CADExtrudeHandleFrame(S: TCADSketch; const Seeds: TCADContourSeeds;
  const Options: TCADExtrudeOptions; Camera: TViewport3DCamera;
  AWidth, AHeight: Integer; out Frame: TCADExtrudeHandleFrame): Boolean;

function CADExtrudeHandleHit(const Frame: TCADExtrudeHandleFrame;
  X, Y: Double; ATolerance: Double): Boolean;

{ Drag takes the depth at drag start plus a projected scalar displacement;
  it does not accumulate rounding error over repeated mouse events. }
function CADExtrudeHandleDepth(const Frame: TCADExtrudeHandleFrame;
  X0, Y0, X1, Y1, AStartDepth: Double): Double;

procedure CADBuildExtrudeHandleMesh(const Frame: TCADExtrudeHandleFrame;
  ASize: Double; Camera: TViewport3DCamera; AMesh: TV3DMeshData);

implementation

function ProjectWorld(Camera: TViewport3DCamera; AWidth, AHeight: Integer;
  const P: TV3Vec; out X, Y: Double): Boolean;
var
  V: TV3Vec;
  Z, Scale: Double;
begin
  Result := False;
  if (Camera = nil) or (AWidth <= 0) or (AHeight <= 0) then Exit;
  V := V3Sub(P, Camera.Eye);
  Z := V3Dot(V, Camera.ForwardDir);
  if Camera.Projection = vpPerspective then
  begin
    if Z <= 1e-8 then Exit;
    Scale := AHeight / (2 * Z * Tan(DegToRad(Camera.FovYDeg) * 0.5));
  end
  else
  begin
    if Camera.OrthoHeight <= 1e-8 then Exit;
    Scale := AHeight / Camera.OrthoHeight;
  end;
  X := AWidth * 0.5 + V3Dot(V, Camera.RightDir) * Scale;
  Y := AHeight * 0.5 - V3Dot(V, Camera.UpDir) * Scale;
  Result := True;
end;

function CADExtrudeHandleFrame(S: TCADSketch; const Seeds: TCADContourSeeds;
  const Options: TCADExtrudeOptions; Camera: TViewport3DCamera;
  AWidth, AHeight: Integer; out Frame: TCADExtrudeHandleFrame): Boolean;
var
  PlaneX, PlaneY, Normal, Origin, Ahead: TV3Vec;
  U, V, X2, Y2, Factor, SignedLength: Double;
  I, Count: Integer;
  P: TCADSketchPlane;
begin
  Result := False;
  Frame := Default(TCADExtrudeHandleFrame);
  if (S = nil) or (Camera = nil) or (Options.Depth <= 0) then Exit;
  P := S.Plane;
  PlaneX := V3(P.XDir[0],P.XDir[1],P.XDir[2]);
  Normal := V3(P.Normal[0],P.Normal[1],P.Normal[2]);
  PlaneY := V3Cross(Normal,PlaneX);
  Origin := V3(P.Origin[0],P.Origin[1],P.Origin[2]);

  if Length(Seeds) > 0 then
  begin
    U := Seeds[0].X;
    V := Seeds[0].Y;
  end
  else
  begin
    U := 0; V := 0; Count := 0;
    for I := 0 to S.PointCount - 1 do
      if S.Points[I].Active then
      begin
        U := U + S.PointX(I);
        V := V + S.PointY(I);
        Inc(Count);
      end;
    if Count > 0 then
    begin
      U := U / Count;
      V := V / Count;
    end;
  end;
  Frame.Base := V3Add(Origin,
    V3Add(V3Scale(PlaneX,U),V3Scale(PlaneY,V)));
  Factor := 1.0;
  if Options.Symmetric then Factor := 0.5;
  if Options.Reversed then Factor := -Factor;
  SignedLength := Options.Depth * Factor;
  Frame.Tip := V3Add(Frame.Base,V3Scale(Normal,SignedLength));
  if not ProjectWorld(Camera,AWidth,AHeight,Frame.Tip,
    Frame.TipX,Frame.TipY) then Exit;

  Ahead := V3Add(Frame.Tip,V3Scale(Normal,Factor));
  if not ProjectWorld(Camera,AWidth,AHeight,Ahead,X2,Y2) then Exit;
  Frame.PixelsXPerMM := X2 - Frame.TipX;
  Frame.PixelsYPerMM := Y2 - Frame.TipY;
  { End-on viewing direction: permit vertical screen dragging instead of
    division by a near-zero projected normal. Sign follows Reverse. }
  if Sqr(Frame.PixelsXPerMM)+Sqr(Frame.PixelsYPerMM)<1e-6 then
  begin
    Frame.PixelsXPerMM := 0;
    Frame.PixelsYPerMM := -Factor / Max(1e-6,Camera.WorldPerPixel(AHeight));
  end;
  Result := True;
end;

function CADExtrudeHandleHit(const Frame: TCADExtrudeHandleFrame;
  X, Y: Double; ATolerance: Double): Boolean;
begin
  Result := Hypot(X-Frame.TipX,Y-Frame.TipY) <= ATolerance;
end;

function CADExtrudeHandleDepth(const Frame: TCADExtrudeHandleFrame;
  X0, Y0, X1, Y1, AStartDepth: Double): Double;
begin
  Result := CADDraggedExtrudeDepth(AStartDepth,
    X1-X0,Y1-Y0,Frame.PixelsXPerMM,Frame.PixelsYPerMM);
end;

procedure CADBuildExtrudeHandleMesh(const Frame: TCADExtrudeHandleFrame;
  ASize: Double; Camera: TViewport3DCamera; AMesh: TV3DMeshData);
var
  R, U, LeftPt, RightPt, UpPt, DownPt: TV3Vec;
begin
  if (AMesh = nil) or (Camera = nil) then Exit;
  AMesh.Clear;
  ASize := Max(0.0001,ASize);
  R := V3Scale(Camera.RightDir, ASize);
  U := V3Scale(Camera.UpDir, ASize);
  LeftPt := V3Sub(Frame.Tip,R);
  RightPt := V3Add(Frame.Tip,R);
  UpPt := V3Add(Frame.Tip,U);
  DownPt := V3Sub(Frame.Tip,U);
  { Axis stroke, diamond at top, and four outward arrow ticks. }
  AMesh.AddPolylineEdge([Frame.Base,Frame.Tip],False,1);
  AMesh.AddPolylineEdge([LeftPt,UpPt,RightPt,DownPt],True,2);
  AMesh.AddPolylineEdge([V3Sub(Frame.Tip,V3Scale(R,1.5)),
    V3Add(Frame.Tip,V3Scale(R,1.5))],False,3);
  AMesh.AddPolylineEdge([V3Sub(Frame.Tip,V3Scale(U,1.5)),
    V3Add(Frame.Tip,V3Scale(U,1.5))],False,4);
  AMesh.AddVertex(Frame.Base,V3(0,0,1),0);
  AMesh.AddVertex(Frame.Tip,V3(0,0,1),0);
end;

end.
