unit CAD.Features.Sketch;
{$mode objfpc}{$H+}

{ ROLE:      Sketch feature: parameter 'geometry' = the sketch as text
             (CAD.Sketch.Text). Compute: load, solve, build the profile,
             make planar OCCT faces (one face or a compound). Registered as
             'Sketch'. No inputs (placement on a model face comes later).
  CALLED BY: TCADDocument (Compute), registry, the app and tests.
  CALLS:     CAD.Sketch.Model / Text / Solver / Profile, CAD.OCCT.Bridge
             (MakePlanarFaces), CAD.Features.OCCTBase.
  THREADS:   Compute on a worker thread; it loads its own sketch copy, so
             nothing is shared.
  SPEED:     the text is hashed once per change (cache key); a solve of an
             already solved sketch stops after the residual check. }

interface

uses
  SysUtils, CAD.Core.Values, CAD.Core.Feature, CAD.Core.FeatureRegistry,
  CAD.OCCT.Bridge, CAD.Features.OCCTBase,
  CAD.Sketch.Model, CAD.Sketch.Text, CAD.Sketch.Solver, CAD.Sketch.Profile;

type
  TCADLongIntArray = array of LongInt;

  TCADSketchFeature = class(TCADOCCTFeature)
  protected
    procedure DefineParams; override;
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; override;
  public
    class function TypeName: string; override;
  end;

{ Parameter value for TCADDocument.SetParam(id, 'geometry', ...). }
function CADSketchValue(S: TCADSketch): TCADValue;
{ Profile -> the arrays of TOCCTLibrary.MakePlanarFaces. }
procedure CADProfileArrays(S: TCADSketch; const P: TCADSketchProfile;
  out APlane, AEdges: TCADDoubleArray; out ALoopSizes, AFaceLoops: TCADLongIntArray);

implementation

function CADSketchValue(S: TCADSketch): TCADValue;
begin
  Result := CADText(CADSketchToText(S));
end;

class function TCADSketchFeature.TypeName: string;
begin
  Result := 'Sketch';
end;

procedure TCADSketchFeature.DefineParams;
begin
  AddParam('geometry', CADText(''));
end;

procedure CADProfileArrays(S: TCADSketch; const P: TCADSketchProfile;
  out APlane, AEdges: TCADDoubleArray; out ALoopSizes, AFaceLoops: TCADLongIntArray);
var
  F, H, NE, NL, I: Integer;

  procedure AddLoop(ALoop: Integer);
  var
    K: Integer;
    E: TCADProfileEdge;
  begin
    ALoopSizes[NL] := Length(P.Loops[ALoop].Edges);
    Inc(NL);
    for K := 0 to High(P.Loops[ALoop].Edges) do
    begin
      E := P.Loops[ALoop].Edges[K];
      AEdges[NE * 9 + 0] := Ord(E.Kind);       { pekLine 0, pekArc 1, pekCircle 2 }
      AEdges[NE * 9 + 1] := E.X1;
      AEdges[NE * 9 + 2] := E.Y1;
      AEdges[NE * 9 + 3] := E.X2;
      AEdges[NE * 9 + 4] := E.Y2;
      AEdges[NE * 9 + 5] := E.CX;
      AEdges[NE * 9 + 6] := E.CY;
      AEdges[NE * 9 + 7] := E.R;
      if E.CCW then
        AEdges[NE * 9 + 8] := 1
      else
        AEdges[NE * 9 + 8] := 0;
      Inc(NE);
    end;
  end;

begin
  SetLength(APlane, 9);
  for I := 0 to 2 do
  begin
    APlane[I] := S.Plane.Origin[I];
    APlane[3 + I] := S.Plane.XDir[I];
    APlane[6 + I] := S.Plane.Normal[I];
  end;
  NE := 0;
  for I := 0 to High(P.Loops) do
    Inc(NE, Length(P.Loops[I].Edges));
  SetLength(AEdges, NE * 9);
  SetLength(ALoopSizes, Length(P.Loops));
  SetLength(AFaceLoops, Length(P.Faces));
  NE := 0;
  NL := 0;
  for F := 0 to High(P.Faces) do
  begin
    AFaceLoops[F] := 1 + Length(P.Faces[F].Holes);
    AddLoop(P.Faces[F].Outer);
    for H := 0 to High(P.Faces[F].Holes) do
      AddLoop(P.Faces[F].Holes[H]);
  end;
  SetLength(ALoopSizes, NL);
end;

function TCADSketchFeature.Compute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
var
  S: TCADSketch;
  R: TCADSketchSolveResult;
  P: TCADSketchProfile;
  Plane, Edges: TCADDoubleArray;
  LoopSizes, FaceLoops: TCADLongIntArray;
  I: Integer;
  List: string;
begin
  AResult := nil;
  S := TCADSketch.Create;
  try
    CADSketchFromText(GetParamValue('geometry').S, S);
    R := CADSolveSketch(S);
    if R.Status <> cssSolved then
    begin
      List := '';
      for I := 0 to High(R.Conflicting) do
        List := List + ' ' + IntToStr(R.Conflicting[I]);
      AError := Format('Sketch: %s (constraints:%s)', [CADSolveStatusText(R.Status), List]);
      Exit(False);
    end;
    if not CADBuildProfile(S, P) then
    begin
      AError := 'Sketch: ' + P.Error;
      Exit(False);
    end;
    CADProfileArrays(S, P, Plane, Edges, LoopSizes, FaceLoops);
    Result := WrapShape(OCCT.MakePlanarFaces(Plane, Edges, LoopSizes, FaceLoops),
      'Sketch', AResult, AError);
  finally
    S.Free;
  end;
end;

initialization
  CADFeatures.Register(TCADSketchFeature);
end.
