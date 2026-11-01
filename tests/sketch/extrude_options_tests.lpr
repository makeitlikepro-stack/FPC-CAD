program extrude_options_tests;
{$mode objfpc}{$H+}

uses
  SysUtils, Math, CAD.Sketch.ExtrudeOptions;

var
  Checks, Failures: Integer;

procedure Check(ACondition: Boolean; const ATest: string);
begin
  Inc(Checks);
  if not ACondition then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', ATest);
  end;
end;

procedure TestDepthValidation;
var
  O: TCADExtrudeOptions;
  Err: string;
  Depth: Double;
begin
  O := CADDefaultExtrudeOptions;
  Check((O.Depth = 10) and not O.Reversed and not O.Symmetric,
    'new extrusion defaults to 10 mm, normal direction, one-sided');
  Check(CADValidateExtrudeOptions(O, Err) and (Err = ''),
    'default settings are valid');

  O.Depth := 0;
  Check(not CADValidateExtrudeOptions(O, Err) and (Err <> ''),
    'zero depth is refused');
  O.Depth := -10;
  Check(not CADValidateExtrudeOptions(O, Err),
    'negative depth is refused; use Reversed instead');
  O.Depth := 1000001;
  Check(not CADValidateExtrudeOptions(O, Err),
    'huge depth is refused');
  O.Depth := Infinity;
  Check(not CADValidateExtrudeOptions(O, Err),
    'infinite depth is refused');
  O.Depth := NaN;
  Check(not CADValidateExtrudeOptions(O, Err),
    'NaN depth is refused');
  O := CADDefaultExtrudeOptions;
  O.Depth := 0.125;
  O.Reversed := True;
  O.Symmetric := True;
  Check(CADValidateExtrudeOptions(O, Err) and O.Reversed and O.Symmetric,
    'fractional symmetric reversed extrusion is a valid setting');

  Check(CADParseExtrudeDepth('12.5', Depth) and (Abs(Depth-12.5)<1e-10),
    'precise dot-decimal depth');
  Check(CADParseExtrudeDepth('12,5', Depth) and (Abs(Depth-12.5)<1e-10),
    'comma decimal entry');
  Check(CADParseExtrudeDepth('0.002', Depth) and (Abs(Depth-0.002)<1e-10),
    'sub-millimetre positive depth');
  Check(not CADParseExtrudeDepth('0', Depth),
    'zero depth cannot enter live preview');
  Check(not CADParseExtrudeDepth('-1', Depth),
    'negative depth cannot enter live preview');
  Check(not CADParseExtrudeDepth('12mm', Depth),
    'units must not silently pass numeric input');
  Check(not CADParseExtrudeDepth('bad', Depth),
    'malformed number rejected');
end;

procedure TestProjectedGrip;
begin
  Check(Abs(CADDraggedExtrudeDepth(10, 0, -50, 0, -5) - 20) < 1e-7,
    'depth grip: dragging 50 px along a -5 px/mm normal adds 10 mm');
  Check(Abs(CADDraggedExtrudeDepth(10, 25, 0, -2.5, 0) - 0.01) < 1e-7,
    'depth grip: reversed direction clamps at a safe positive depth');
  Check(Abs(CADDraggedExtrudeDepth(10, 10, -10, 3, -4) - 12.8) < 1e-7,
    'depth grip: diagonal drag projects onto the actual 3D extrusion axis');
  Check(Abs(CADDraggedExtrudeDepth(10, 15, 20, 3, -4) - 8.6) < 1e-7,
    'depth grip: perpendicular movement is projected, not taken as Y only');
  Check(Abs(CADDraggedExtrudeDepth(10, 1000, 0, 0, 0) - 10) < 1e-7,
    'depth grip: degenerate projection keeps the original depth');
  Check(Abs(CADDraggedExtrudeDepth(10, 100, 0, 2.5, 0) - 50) < 1e-7,
    'depth grip: symmetric half-size axis maps to twice the depth');
end;

begin
  Checks := 0;
  Failures := 0;
  TestDepthValidation;
  TestProjectedGrip;
  if Failures = 0 then
    WriteLn(Format('PASS: extrusion depth/direction options (%d checks)',[Checks]))
  else
    WriteLn(Format('FAIL: extrusion options %d of %d checks failed',[Failures,Checks]));
  if Failures > 0 then Halt(1);
end.
