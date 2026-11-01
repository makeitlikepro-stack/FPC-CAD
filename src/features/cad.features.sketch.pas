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
  CAD.Sketch.Model, CAD.Sketch.Text, CAD.Sketch.Solver, CAD.Sketch.Profile,
  CAD.Sketch.Regions, CAD.Sketch.ContourSelection;

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
  { ALL means every region for backwards compatibility. A v1 list stores
    the user-picked interior points and survives face-index reordering. }
  AddParam('contours', CADText('ALL'));
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
  { The region arrangement also stores outside-face cycles which are NOT
    referenced by selected bounded faces. Remove the unused edge capacity
    before passing the buffer to OCCT. }
  SetLength(AEdges, NE * 9);
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
  Seeds: TCADContourSeeds;
  Indices: TCADRegionIndices;
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
    if not CADContoursFromText(GetParamValue('contours').S, Seeds) then
    begin
      AError := 'Sketch: invalid selected contours data';
      Exit(False);
    end;
    if Length(Seeds)=0 then
    begin
      { Preserve old hole semantics: a clean closed sketch with an outer
        rectangle and circular holes still extrudes AS A PLATE WITH HOLES.
        Untrimmed intersecting/open-arm geometry falls back to the new
        planar-region arrangement because the legacy builder rejects it. }
      if not CADBuildProfile(S, P) then
        if not CADBuildRegions(S, P) then
        begin
          { Both builders agree that an open contour has no closed face.
            Keep the historic "open profile" diagnostic for callers and
            regression tests; don't confuse this with an OCCT failure. }
          if P.Error = 'no bounded sketch regions' then
            AError := 'Sketch: open profile (no bounded sketch regions)'
          else
            AError := 'Sketch regions: ' + P.Error;
          Exit(False);
        end;
    end
    else
    begin
      if not CADBuildRegions(S, P) then
      begin
        AError := 'Sketch regions: ' + P.Error;
        Exit(False);
      end;
      Indices := CADContourIndices(P, Seeds);
      if Length(Indices)=0 then
      begin
        AError := 'Sketch: no selected contour remains after geometry changes';
        Exit(False);
      end;
      P := CADRegionProfileSubset(P, Indices);
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
