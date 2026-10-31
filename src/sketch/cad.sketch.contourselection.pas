unit CAD.Sketch.ContourSelection;
{$mode objfpc}{$H+}

{ ROLE: Stable click-position references for selected planar sketch contours.
  Selection persists in a feature parameter, not in sketch geometry. The
  points are resolved again after sketch edits, so face-array order may
  change without silently changing the selected region. }

interface

uses
  SysUtils, Classes, CAD.Sketch.Profile, CAD.Sketch.Regions;

type
  TCADContourSeed = record
    X,Y:Double;
  end;
  TCADContourSeeds = array of TCADContourSeed;
  TCADRegionIndices = array of Integer;

{ Empty seeds means all bounded regions, matching legacy Extrude behaviour.
  Nonempty seeds mean ONLY the selected regions. }
function CADContourIndices(const P:TCADSketchProfile;
  const Seeds:TCADContourSeeds):TCADRegionIndices;

{ One click replaces selection; shift-click toggles a region. Unmatched
  clicks do not append invalid contours. Returns True when selection changes. }
function CADClickContour(const P:TCADSketchProfile; X,Y:Double;
  AAdd:Boolean; var Seeds:TCADContourSeeds):Boolean;

{ ALL or v1:<x>,<y>;<x>,<y>... (dot decimal, locale independent). }
function CADContoursToText(const Seeds:TCADContourSeeds):String;
function CADContoursFromText(const AText:String;
  out Seeds:TCADContourSeeds):Boolean;

implementation

function CADContourIndices(const P:TCADSketchProfile;
  const Seeds:TCADContourSeeds):TCADRegionIndices;
var I,J,K,N:Integer; Present:Boolean;
begin
  SetLength(Result,0);
  if Length(Seeds)=0 then
  begin
    SetLength(Result,Length(P.Faces));
    for I:=0 to High(P.Faces) do Result[I]:=I;
    Exit;
  end;
  for I:=0 to High(Seeds) do
  begin
    K:=CADPickRegion(P,Seeds[I].X,Seeds[I].Y);
    if K<0 then Continue;
    Present:=False;
    for J:=0 to High(Result) do
      if Result[J]=K then Present:=True;
    if Present then Continue;
    N:=Length(Result);
    SetLength(Result,N+1);
    Result[N]:=K;
  end;
end;

function CADClickContour(const P:TCADSketchProfile; X,Y:Double;
  AAdd:Boolean; var Seeds:TCADContourSeeds):Boolean;
var K,I,J,N,Found:Integer; CopySeeds:TCADContourSeeds;
begin
  Result:=False;
  K:=CADPickRegion(P,X,Y);
  if K<0 then Exit;
  if not AAdd then
  begin
    Result:=(Length(Seeds)<>1);
    if Length(Seeds)=1 then
      Result:=CADPickRegion(P,Seeds[0].X,Seeds[0].Y)<>K;
    SetLength(Seeds,1);
    Seeds[0].X:=X;
    Seeds[0].Y:=Y;
    Exit;
  end;
  Found:=-1;
  for I:=0 to High(Seeds) do
    if CADPickRegion(P,Seeds[I].X,Seeds[I].Y)=K then
    begin
      Found:=I; Break;
    end;
  if Found>=0 then
  begin
    for J:=Found to High(Seeds)-1 do Seeds[J]:=Seeds[J+1];
    SetLength(Seeds,Length(Seeds)-1);
    Exit(True);
  end;
  N:=Length(Seeds);
  SetLength(Seeds,N+1);
  Seeds[N].X:=X;
  Seeds[N].Y:=Y;
  Result:=True;
end;

function CADContoursToText(const Seeds:TCADContourSeeds):String;
var I:Integer; F:TFormatSettings;
begin
  if Length(Seeds)=0 then Exit('ALL');
  F:=DefaultFormatSettings;
  F.DecimalSeparator:='.';
  Result:='v1:';
  for I:=0 to High(Seeds) do
  begin
    if I>0 then Result:=Result+';';
    Result:=Result+FloatToStrF(Seeds[I].X,ffGeneral,17,0,F)+','+
      FloatToStrF(Seeds[I].Y,ffGeneral,17,0,F);
  end;
end;

function CADContoursFromText(const AText:String;
  out Seeds:TCADContourSeeds):Boolean;
var TextPart,Item,PairLeft,PairRight:String;
    F:TFormatSettings; Segments:TStringList;
    I,J,N:Integer;
begin
  SetLength(Seeds,0);
  TextPart:=Trim(AText);
  if (TextPart='') or (TextPart='ALL') then Exit(True);
  Result:=False;
  if Copy(TextPart,1,3)<>'v1:' then Exit;
  Delete(TextPart,1,3);
  if TextPart='' then Exit;
  F:=DefaultFormatSettings;
  F.DecimalSeparator:='.';
  Segments:=TStringList.Create;
  try
    Segments.StrictDelimiter:=True;
    Segments.Delimiter:=';';
    Segments.DelimitedText:=TextPart;
    for I:=0 to Segments.Count-1 do
    begin
      Item:=Trim(Segments[I]);
      J:=Pos(',',Item);
      if J<=1 then Exit;
      PairLeft:=Copy(Item,1,J-1);
      PairRight:=Copy(Item,J+1,Length(Item));
      N:=Length(Seeds);
      SetLength(Seeds,N+1);
      if not TryStrToFloat(PairLeft,Seeds[N].X,F) then Exit;
      if not TryStrToFloat(PairRight,Seeds[N].Y,F) then Exit;
    end;
    Result:=True;
  finally
    Segments.Free;
    if not Result then SetLength(Seeds,0);
  end;
end;

end.
