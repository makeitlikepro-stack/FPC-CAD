program trim_extend_tests;
{$mode objfpc}{$H+}

{ Pure, headless geometry tests for CAD.Sketch.TrimExtend. }

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.TrimExtend,
  CAD.Sketch.Text, CAD.Sketch.Commands, CAD.Sketch.Solver;

var
  Checks, Failures: Integer;

procedure Check(AOk: Boolean; const AName: string);
begin
  Inc(Checks);
  if not AOk then
  begin
    Inc(Failures);
    WriteLn('FAIL  ', AName);
  end;
end;

function Near(A, B: Double): Boolean;
begin
  Result := Abs(A - B) < 1e-7;
end;

procedure TestTrimEnd;
var
  S: TCADSketch;
  Line: Integer;
  P: TCADLineEditPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(4, -4, 4, 4);
    Check(CADPlanLineEdit(S, Line, 1, 0, lemTrim, P, Err) and
      (P.Endpoint = leStart) and Near(P.X, 4) and Near(P.Y, 0),
      'trim: click before crossing moves line start');
    Check(CADPlanLineEdit(S, Line, 9, 0, lemTrim, P, Err) and
      (P.Endpoint = leEnd) and Near(P.X, 4),
      'trim: click after crossing moves line end');
    Check(Near(S.PointX(S.Entities[Line].P1), 0) and
      Near(S.PointX(S.Entities[Line].P2), 10),
      'trim: planning leaves the original sketch unchanged');
    Check(not CADPlanLineEdit(S, Line, 4, 0, lemTrim, P, Err) and (Err <> ''),
      'trim: clicking on the intersection is not an unintentional edit');
  finally
    S.Free;
  end;
end;

procedure TestMiddleTrim;
var
  S: TCADSketch;
  Line: Integer;
  P: TCADLineEditPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(3, -3, 3, 3);
    S.AddLineXY(7, -3, 7, 3);
    Check(CADPlanLineEdit(S, Line, 1, 0, lemTrim, P, Err) and
      Near(P.X, 3) and (P.Endpoint = leStart),
      'trim: first outer span stops at first crossing');
    Check(CADPlanLineEdit(S, Line, 9, 0, lemTrim, P, Err) and
      Near(P.X, 7) and (P.Endpoint = leEnd),
      'trim: last outer span stops at last crossing');
    Check(not CADPlanLineEdit(S, Line, 5, 0, lemTrim, P, Err) and
      (Pos('split', Err) > 0),
      'trim: a middle span is refused until entity splitting is available');
  finally
    S.Free;
  end;
end;

procedure TestExtend;
var
  S: TCADSketch;
  Line: Integer;
  P: TCADLineEditPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 2, 0);
    S.AddLineXY(5, -4, 5, 4);
    S.AddLineXY(8, -4, 8, 4);
    S.AddLineXY(-3, -4, -3, 4);
    Check(CADPlanLineEdit(S, Line, 2, 0, lemExtend, P, Err) and
      (P.Endpoint = leEnd) and Near(P.X, 5),
      'extend: nearest boundary on the right is chosen');
    Check(CADPlanLineEdit(S, Line, 0, 0, lemExtend, P, Err) and
      (P.Endpoint = leStart) and Near(P.X, -3),
      'extend: nearest boundary on the left is chosen');
    Check(Near(S.PointX(S.Entities[Line].P2), 2),
      'extend: planning leaves the original endpoint unchanged');
  finally
    S.Free;
  end;
end;

procedure TestNoBoundary;
var
  S: TCADSketch;
  Line: Integer;
  P: TCADLineEditPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(5, 2, 5, 4);  { infinite support crosses, segment does not }
    Check(not CADPlanLineEdit(S, Line, 8, 0, lemTrim, P, Err) and (Err <> ''),
      'trim: intersection outside boundary segment is ignored');
    Check(not CADPlanLineEdit(S, Line, 8, 0, lemExtend, P, Err),
      'extend: no intersection beyond endpoint');
    Check(not CADPlanLineEdit(S, 999, 0, 0, lemTrim, P, Err),
      'invalid line index is rejected');
  finally
    S.Free;
  end;
end;

{ Power Trim deletes precisely the clicked part, including between two
  intersections; the old line remains as an inactive stable-ID tombstone. }
procedure TestCutMiddleAndUndoFormat;
var
  S, Restored: TCADSketch;
  Line, I, L, R: Integer;
  Plan: TCADTrimPlan;
  Err, Encoded: string;
begin
  S := TCADSketch.Create;
  Restored := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(3, -4, 3, 4);
    S.AddLineXY(7, -4, 7, 4);
    Check(CADPlanLineTrim(S, Line, 5, 0, Plan, Err) and
      Near(Plan.FromT, 0.3) and Near(Plan.ToT, 0.7),
      'power trim: clicking the middle chooses the segment 3..7 (' + Err + ')');
    Check(CADApplyLineTrim(S, Plan, Err),
      'power trim: remove the clicked middle span (' + Err + ')');
    Check(not S.Entities[Line].Active,
      'power trim: the original 0..10 line is inactive');
    L := 3;
    R := 4;
    Check((S.EntityCount = 5) and S.Entities[L].Active and S.Entities[R].Active and
      Near(S.PointX(S.Entities[L].P1), 0) and
      Near(S.PointX(S.Entities[L].P2), 3) and
      Near(S.PointX(S.Entities[R].P1), 7) and
      Near(S.PointX(S.Entities[R].P2), 10),
      'power trim: actual geometry is 0..3 and 7..10 (a real gap)');
    Check(CADSketchHit(S, 5, 0, 0.2, I) = chkNone,
      'power trim: the removed portion cannot be selected');
    Encoded := CADSketchToText(S);
    CADSketchFromText(Encoded, Restored);
    Check((Restored.EntityCount = 5) and (not Restored.Entities[Line].Active) and
      (CADSketchToText(Restored) = Encoded),
      'power trim: saved and restored sketch keeps the removed segment');
    Check(CADSketchHit(Restored, 5, 0, 0.2, I) = chkNone,
      'power trim: saved sketch does not bring back deleted line');
  finally
    Restored.Free;
    S.Free;
  end;
end;

procedure TestCutEndWholeAndConstraints;
var
  S: TCADSketch;
  Line, I, C: Integer;
  Plan: TCADTrimPlan;
  Err, Before: string;
begin
  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(4, -4, 4, 4);
    Check(CADPlanLineTrim(S, Line, 2, 0, Plan, Err) and
      Near(Plan.FromT, 0) and Near(Plan.ToT, 0.4) and
      CADApplyLineTrim(S, Plan, Err) and
      Near(S.PointX(S.Entities[2].P1), 4) and
      Near(S.PointX(S.Entities[2].P2), 10),
      'power trim: left end deleted, right segment survives');
    Check(CADSketchHit(S, 1, 0, 0.2, I) = chkNone,
      'power trim: the removed tail is not pickable');
  finally
    S.Free;
  end;

  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    Check(CADPlanLineTrim(S, Line, 5, 0, Plan, Err) and
      Near(Plan.FromT, 0) and Near(Plan.ToT, 1) and
      CADApplyLineTrim(S, Plan, Err),
      'power trim: a line without crossings can be deleted entirely');
    Check((not S.Entities[Line].Active) and
      (not S.Points[S.Entities[Line].P1].Active) and
      (not S.Points[S.Entities[Line].P2].Active),
      'power trim: no stray orphan points after deleting whole line');
    Check(CADSolveSketch(S).Status = cssSolved,
      'power trim: empty sketch remains solvable');
  finally
    S.Free;
  end;

  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(3, -4, 3, 4);
    S.AddLineXY(7, -4, 7, 4);
    C := S.Horizontal(Line);
    Check(CADPlanLineTrim(S, Line, 5, 0, Plan, Err) and
      CADApplyLineTrim(S, Plan, Err) and (not S.Constraints[C].Active) and
      (S.Constraints[S.ConstraintCount-1].Kind = sckHorizontal),
      'power trim: horizontal constraint recreated for surviving segments');
  finally
    S.Free;
  end;

  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(3, -4, 3, 4);
    S.AddLineXY(7, -4, 7, 4);
    S.Length(Line, 10);
    Before := CADSketchToText(S);
    Check(CADPlanLineTrim(S, Line, 5, 0, Plan, Err) and
      not CADApplyLineTrim(S, Plan, Err) and
      (CADSketchToText(S) = Before),
      'power trim: unsupported dimension remapping refuses without mutation');
  finally
    S.Free;
  end;
end;

procedure TestCommitAndSafety;
var
  S: TCADSketch;
  Line, P2: Integer;
  Plan: TCADLineEditPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(4, -3, 4, 3);
    Check(CADPlanLineEdit(S, Line, 9, 0, lemTrim, Plan, Err) and
      CADApplyLineEdit(S, Plan, Err) and
      Near(S.PointX(S.Entities[Line].P2), 4),
      'commit: isolated line endpoint is trimmed to the boundary (' + Err + ')');
    S.AddLineXY(8, -3, 8, 3);
    Check(CADPlanLineEdit(S, Line, 4, 0, lemExtend, Plan, Err) and
      CADApplyLineEdit(S, Plan, Err) and
      Near(S.PointX(S.Entities[Line].P2), 8),
      'commit: isolated line endpoint is extended (' + Err + ')');
  finally
    S.Free;
  end;

  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(4, -3, 4, 3);
    P2 := S.Entities[Line].P2;
    S.AddLine(P2, S.AddPoint(12, 2));
    Check(CADPlanLineEdit(S, Line, 9, 0, lemTrim, Plan, Err) and
      not CADApplyLineEdit(S, Plan, Err) and
      Near(S.PointX(P2), 10),
      'commit: shared endpoint is refused without moving connected line');
  finally
    S.Free;
  end;

  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(4, -3, 4, 3);
    P2 := S.Entities[Line].P2;
    S.FixPoint(P2);
    Check(CADPlanLineEdit(S, Line, 9, 0, lemTrim, Plan, Err) and
      not CADApplyLineEdit(S, Plan, Err) and
      Near(S.PointX(P2), 10),
      'commit: a fixed endpoint is refused');
  finally
    S.Free;
  end;

  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(4, -3, 4, 3);
    S.Length(Line, 10);
    Check(CADPlanLineEdit(S, Line, 9, 0, lemTrim, Plan, Err) and
      not CADApplyLineEdit(S, Plan, Err) and
      Near(S.PointX(S.Entities[Line].P2), 10),
      'commit: length-constrained line is refused');
  finally
    S.Free;
  end;
end;

begin
  Checks := 0;
  Failures := 0;
  TestTrimEnd;
  TestMiddleTrim;
  TestExtend;
  TestNoBoundary;
  TestCommitAndSafety;
  TestCutMiddleAndUndoFormat;
  TestCutEndWholeAndConstraints;
  if Failures = 0 then
    WriteLn(Format('PASS  trim/extend planning: %d checks', [Checks]))
  else
    WriteLn(Format('FAIL  trim/extend planning: %d of %d checks failed',
      [Failures, Checks]));
  if Failures > 0 then Halt(1);
end.
