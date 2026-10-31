program region_tests;
{$mode objfpc}{$H+}

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.Regions,
  CAD.Sketch.Profile, CAD.Sketch.Text;

var
  Total, Failed:Integer;

procedure Check(OK:Boolean; const Name:string);
begin
  Inc(Total);
  if not OK then
  begin
    Inc(Failed);
    WriteLn('FAIL: ',Name);
  end;
end;

function Near(A,B:Double):Boolean;
begin
  Result:=Abs(A-B)<1e-5;
end;

procedure Rectangle(S:TCADSketch; X0,Y0,W,H:Double);
begin
  S.AddLineXY(X0,Y0,X0+W,Y0);
  S.AddLineXY(X0+W,Y0,X0+W,Y0+H);
  S.AddLineXY(X0+W,Y0+H,X0,Y0+H);
  S.AddLineXY(X0,Y0+H,X0,Y0);
end;

procedure TestFourAreas;
var
  S:TCADSketch;
  P,Q:TCADSketchProfile;
  Before:string;
  Pick:array[0..1] of Integer;
begin
  S:=TCADSketch.Create;
  try
    Rectangle(S,0,0,10,10);
    S.AddLineXY(5,-2,5,12);
    S.AddLineXY(-2,5,12,5);
    Before:=CADSketchToText(S);
    Check(CADBuildRegions(S,P),'crossed rectangle: extract planar regions ('+P.Error+')');
    Check(Length(P.Faces)=4,'crossed rectangle: four independent regions');
    if Length(P.Faces)=4 then
    begin
      Check(Near(P.Faces[0].Area+P.Faces[1].Area+
        P.Faces[2].Area+P.Faces[3].Area,100),
        'crossed rectangle: sum area = 100, no overlapping extrudes');
      Check((CADPickRegion(P,2,2)>=0) and
        (CADPickRegion(P,8,2)>=0) and
        (CADPickRegion(P,2,8)>=0) and
        (CADPickRegion(P,8,8)>=0),
        'crossed rectangle: pick any quadrant');
      Check((CADPickRegion(P,-1,-1)=-1) and
        (CADPickRegion(P,5,11)=-1),
        'crossed rectangle: exterior lines do not create invalid faces');
      Pick[0]:=CADPickRegion(P,2,2);
      Pick[1]:=CADPickRegion(P,8,8);
      Check(Pick[0]<>Pick[1],'crossed rectangle: picks identify different faces');
      Q:=CADRegionProfileSubset(P,Pick);
      Check(Length(Q.Faces)=2,'crossed rectangle: two selected faces for OCCT');
      Check(Near(Q.Faces[0].Area+Q.Faces[1].Area,50),
        'crossed rectangle: selected contour area is 50');
    end;
    Check(CADSketchToText(S)=Before,
      'crossed rectangle: virtual splitting does not mutate sketch or constraints');
  finally
    S.Free;
  end;
end;

procedure TestOpenBranches;
var
  S:TCADSketch;
  P:TCADSketchProfile;
begin
  S:=TCADSketch.Create;
  try
    Rectangle(S,-5,-5,10,10);
    S.AddLineXY(-5,2,-9,2);
    Check(CADBuildRegions(S,P) and (Length(P.Faces)=1),
      'open branches: dangling line does not stop region discovery');
    if Length(P.Faces)=1 then Check(Near(P.Faces[0].Area,100),
      'open branches: external spur does not contribute to face');
    Check(CADPickRegion(P,-7,2)=-1,
      'open branches: dangling line alone has no selectable region');
  finally S.Free; end;
end;

procedure TestCircleAndLine;
var
  S:TCADSketch;
  P:TCADSketchProfile;
begin
  S:=TCADSketch.Create;
  try
    S.AddCircle(S.AddPoint(0,0),5);
    S.AddLineXY(-8,0,8,0);
    Check(CADBuildRegions(S,P) and (Length(P.Faces)=2),
      'circle + secant: no Trim required to find two semicircles');
    if Length(P.Faces)=2 then
      Check(Near(P.Faces[0].Area+P.Faces[1].Area,25*Pi),
        'circle + secant: exact arc areas combine into original circle area');
    Check((CADPickRegion(P,0,2)<>CADPickRegion(P,0,-2)) and
      (CADPickRegion(P,0,2)>=0) and (CADPickRegion(P,0,-2)>=0),
      'circle + secant: each semicircle independently selectable');
  finally S.Free; end;
end;

procedure TestCircleCircle;
var
  S:TCADSketch;
  P:TCADSketchProfile;
  A,B,C:Integer;
begin
  S:=TCADSketch.Create;
  try
    S.AddCircle(S.AddPoint(0,0),5);
    S.AddCircle(S.AddPoint(6,0),5);
    Check(CADBuildRegions(S,P) and (Length(P.Faces)=3),
      'intersecting circles: lens and both caps are separate regions');
    A:=CADPickRegion(P,-3,0);
    B:=CADPickRegion(P,3,0);
    C:=CADPickRegion(P,9,0);
    Check((A>=0) and (B>=0) and (C>=0) and (A<>B) and
      (B<>C) and (A<>C),
      'intersecting circles: left cap, lens, right cap all pickable');
  finally S.Free; end;
end;

procedure TestNestedHoles;
var
  S:TCADSketch;
  P:TCADSketchProfile;
  Inner,Outer,CI,CO:Integer;
begin
  S:=TCADSketch.Create;
  try
    S.AddCircle(S.AddPoint(0,0),10);
    S.AddCircle(S.AddPoint(0,0),5);
    Check(CADBuildRegions(S,P) and (Length(P.Faces)=2),
      'nested circles: detect annulus and centre disk');
    Inner:=CADPickRegion(P,0,0);
    Outer:=CADPickRegion(P,7,0);
    CI:=-1; CO:=-1;
    if (Inner>=0) and (Inner<Length(P.Faces)) then
      CI:=Length(P.Faces[Inner].Holes);
    if (Outer>=0) and (Outer<Length(P.Faces)) then
      CO:=Length(P.Faces[Outer].Holes);
    Check((Inner>=0) and (Outer>=0) and (Inner<>Outer) and
      (CI=0) and (CO=1),
      'nested circles: central disk and ring-with-one-hole');
    if Outer>=0 then Check(Near(P.Faces[Outer].Area,75*Pi),
      'annulus area: exact outer minus inner circle');
  finally S.Free; end;
end;

procedure TestConstructionAndUnconnected;
var
  S:TCADSketch;
  P:TCADSketchProfile;
  L:Integer;
begin
  S:=TCADSketch.Create;
  try
    Rectangle(S,0,0,10,10);
    L:=S.AddLineXY(0,5,10,5);
    S.SetConstruction(L,True);
    Check(CADBuildRegions(S,P) and (Length(P.Faces)=1),
      'construction geometry: no division of selectable face');
    L:=S.AddLineXY(20,0,25,0);
    Check(CADBuildRegions(S,P) and (Length(P.Faces)=1),
      'unconnected sketch line does not invalidate other faces');
    Check(CADPickRegion(P,22,1)=-1,
      'open line without a loop does not create false face');
  finally S.Free; end;
end;

procedure TestOverlapRejection;
var
  S:TCADSketch;
  P:TCADSketchProfile;
begin
  S:=TCADSketch.Create;
  try
    S.AddLineXY(0,0,10,0);
    S.AddLineXY(5,0,15,0);
    Check(not CADBuildRegions(S,P) and (Pos('overlapping',P.Error)>0),
      'overlapping collinear entities explicitly rejected (no fabricated faces)');
  finally S.Free; end;
end;

begin
  Total:=0; Failed:=0;
  TestFourAreas;
  TestOpenBranches;
  TestCircleAndLine;
  TestCircleCircle;
  TestNestedHoles;
  TestConstructionAndUnconnected;
  TestOverlapRejection;
  if Failed=0 then
    WriteLn(Format('PASS: non-destructive region extraction (%d checks)',[Total]))
  else
    WriteLn(Format('FAIL: region extraction (%d/%d checks)',[Failed,Total]));
  if Failed>0 then Halt(1);
end.
