program trim_extend_tests;
{$mode objfpc}{$H+}

{ Pure, headless geometry tests for CAD.Sketch.TrimExtend. }

uses
  SysUtils, Math, CAD.Sketch.Model, CAD.Sketch.TrimExtend,
  CAD.Sketch.Text, CAD.Sketch.Commands, CAD.Sketch.Solver,
  CAD.Sketch.CurveTrim;

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
  P: TCADTrimPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(4, -4, 4, 4);
    Check(CADPlanLineTrim(S, Line, 1, 0, P, Err) and
      Near(P.FromT, 0) and Near(P.ToT, 0.4),
      'trim: click left removes span 0..4');
    Check(CADPlanLineTrim(S, Line, 9, 0, P, Err) and
      Near(P.FromT, 0.4) and Near(P.ToT, 1),
      'trim: click right removes span 4..10');
    Check(Near(S.PointX(S.Entities[Line].P1), 0) and
      Near(S.PointX(S.Entities[Line].P2), 10),
      'trim: planning does not alter original sketch');
    Check(not CADPlanLineTrim(S, Line, 4, 0, P, Err) and (Err <> ''),
      'trim: click exactly on crossing refuses ambiguity');
  finally
    S.Free;
  end;
end;

procedure TestMiddleTrim;
var
  S: TCADSketch;
  Line: Integer;
  P: TCADTrimPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(0, 0, 10, 0);
    S.AddLineXY(3, -3, 3, 3);
    S.AddLineXY(7, -3, 7, 3);
    Check(CADPlanLineTrim(S, Line, 1, 0, P, Err) and
      Near(P.FromT, 0) and Near(P.ToT, 0.3),
      'trim: first outer span is 0..3');
    Check(CADPlanLineTrim(S, Line, 9, 0, P, Err) and
      Near(P.FromT, 0.7) and Near(P.ToT, 1),
      'trim: last outer span is 7..10');
    Check(CADPlanLineTrim(S, Line, 5, 0, P, Err) and
      Near(P.FromT, 0.3) and Near(P.ToT, 0.7),
      'trim: clicking the middle chooses 3..7 for deletion');
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
procedure TestOldSketchFormatStillLoads;
var
  S: TCADSketch;
  OldFormat: string;
begin
  { Pre-trim FPCSKETCH 1 had no Active flag on points or entities. }
  OldFormat := 'FPCSKETCH 1' + LineEnding +
    'plane 0 0 0 1 0 0 0 0 1' + LineEnding +
    'P 0 0 0' + LineEnding +
    'P 10 0 0' + LineEnding +
    'L 0 1 0' + LineEnding;
  S := TCADSketch.Create;
  try
    CADSketchFromText(OldFormat, S);
    Check((S.EntityCount = 1) and (S.PointCount = 2) and
      S.Entities[0].Active and S.Points[0].Active and S.Points[1].Active,
      'trim: legacy FPCSKETCH 1 reopens with visible geometry');
  finally
    S.Free;
  end;
end;

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
    Check(Pos('FPCSKETCH 2', Encoded) = 1,
      'power trim: deleted geometry uses version 2 to block old readers');
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
  SolveResult: TCADSketchSolveResult;
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
    SolveResult := CADSolveSketch(S);
    Check(SolveResult.Status = cssSolved,
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

{ The curved part of the sketch must be physically cut, not painted over.
  In each case, the gap must no longer be selectable. }
procedure TestCircleCutByLine;
var
  S, Reopened: TCADSketch;
  Circle, Arc, Center, Hit: Integer;
  Plan: TCADTrimPlan;
  Err, Saved: string;
  Solve: TCADSketchSolveResult;
begin
  S := TCADSketch.Create;
  Reopened := TCADSketch.Create;
  try
    Center := S.AddPoint(0, 0);
    Circle := S.AddCircle(Center, 5);
    S.AddLineXY(-10, 0, 10, 0);
    Check(CADPlanSketchTrim(S, Circle, 0, 5, Plan, Err) and
      Near(Plan.FromT, 0) and Near(Plan.ToT, 0.5),
      'curve trim: top circle half bounded by horizontal line');
    Check(CADApplySketchTrim(S, Plan, Err),
      'curve trim: click on top circle half removes it (' + Err + ')');
    Arc := S.EntityCount - 1;
    Check((not S.Entities[Circle].Active) and
      S.Entities[Arc].Active and (S.Entities[Arc].Kind = sekArc) and
      Near(S.PointX(S.Entities[Arc].P1), -5) and
      Near(S.PointX(S.Entities[Arc].P2), 5),
      'curve trim: bottom semicircle remains as a real arc');
    Check(CADSketchHit(S, 0, 5, 0.2, Hit) = chkNone,
      'curve trim: deleted top half is not pickable');
    Check(CADSketchHit(S, 0, -5, 0.2, Hit) = chkEntity,
      'curve trim: remaining bottom half is pickable');
    Check(S.Fixed[S.Entities[Circle].RadiusParam],
      'curve trim: retired circle radius has no phantom solver DOF');
    Solve := CADSolveSketch(S);
    Check(Solve.Status = cssSolved,
      'curve trim: circle-to-arc sketch still solves');
    Saved := CADSketchToText(S);
    Check(Pos('FPCSKETCH 2', Saved) = 1,
      'curve trim: circle deletion saves as v2');
    CADSketchFromText(Saved, Reopened);
    Check((CADSketchToText(Reopened) = Saved) and
      (CADSketchHit(Reopened, 0, 5, 0.2, Hit) = chkNone),
      'curve trim: circle cut survives save/load and undo snapshots');
  finally
    Reopened.Free;
    S.Free;
  end;
end;

procedure TestCircleCutWithManyCrossings;
var
  S: TCADSketch;
  Center, Circle, Hit: Integer;
  Plan: TCADTrimPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Center := S.AddPoint(0, 0);
    Circle := S.AddCircle(Center, 5);
    S.AddLineXY(-3, -8, -3, 8);
    S.AddLineXY(3, -8, 3, 8);
    Check(CADPlanSketchTrim(S, Circle, 0, 5, Plan, Err) and
      (Plan.FromT > 0) and (Plan.ToT < 0.5),
      'curve trim: nearest two of four circle crossings enclose top arc');
    Check(CADApplySketchTrim(S, Plan, Err),
      'curve trim: circle with four crossings removes only clicked arc');
    Check((CADSketchHit(S, 0, 5, 0.2, Hit) = chkNone) and
      (CADSketchHit(S, 0, -5, 0.2, Hit) = chkEntity),
      'curve trim: bottom arc retained when top arc is deleted');
  finally
    S.Free;
  end;
end;

procedure TestCircleCircleIntersection;
var
  S: TCADSketch;
  Circle, Hit: Integer;
  Plan: TCADTrimPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Circle := S.AddCircle(S.AddPoint(0, 0), 5);
    S.AddCircle(S.AddPoint(6, 0), 5);
    Check(CADPlanSketchTrim(S, Circle, 5, 0, Plan, Err) and
      (Plan.FromT < 0) and (Plan.ToT > 0),
      'curve trim: circle-circle intersection handles cyclic wrap at 0 degrees');
    Check(CADApplySketchTrim(S, Plan, Err),
      'curve trim: click on small right arc cuts between two circular crossings');
    Check(CADSketchHit(S, 5, 0, 0.2, Hit) = chkNone,
      'curve trim: right-hand removed segment is not pickable');
    Check(CADSketchHit(S, -5, 0, 0.2, Hit) = chkEntity,
      'curve trim: opposite curved segment is retained');
  finally
    S.Free;
  end;
end;

procedure TestArcCutByLine;
var
  S: TCADSketch;
  Center, Arc, Other, Hit: Integer;
  Plan: TCADTrimPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Center := S.AddPoint(0, 0);
    Arc := S.AddArc(Center, S.AddPoint(5, 0), S.AddPoint(-5, 0));
    S.AddLineXY(0, -7, 0, 7);
    Check(CADPlanSketchTrim(S, Arc, 3.535533906, 3.535533906,
      Plan, Err) and Near(Plan.FromT, 0) and Near(Plan.ToT, 0.5),
      'curve trim: upper semicircle cut at vertical boundary');
    Check(CADApplySketchTrim(S, Plan, Err),
      'curve trim: remove beginning of arc at upper crossing (' + Err + ')');
    Other := S.EntityCount - 1;
    Check((not S.Entities[Arc].Active) and S.Entities[Other].Active and
      (S.Entities[Other].Kind = sekArc) and
      Near(S.PointY(S.Entities[Other].P1), 5) and
      Near(S.PointX(S.Entities[Other].P2), -5),
      'curve trim: preserve the second half of the curved entity');
    Check((CADSketchHit(S, 3.535533906, 3.535533906, 0.2, Hit) = chkNone) and
      (CADSketchHit(S, -3.535533906, 3.535533906, 0.2, Hit) = chkEntity),
      'curve trim: removed arc is not pickable, survivor still is');
  finally
    S.Free;
  end;
end;

procedure TestArcCutByCircleAndArc;
var
  S: TCADSketch;
  Arc, Hit: Integer;
  Plan: TCADTrimPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Arc := S.AddArc(S.AddPoint(0, 0), S.AddPoint(5, 0), S.AddPoint(-5, 0));
    S.AddCircle(S.AddPoint(6, 0), 5);
    Check(CADPlanSketchTrim(S, Arc, 4.6984631, 1.7101007, Plan, Err) and
      (Plan.ToT > 0.25) and (Plan.ToT < 0.4),
      'curve trim: arc against circle clips only true upper intersection');
    Check(CADApplySketchTrim(S, Plan, Err),
      'curve trim: arc-to-circle removes selected part (' + Err + ')');
    Check((CADSketchHit(S, 4.6984631, 1.7101007, 0.1, Hit) = chkNone) and
      (CADSketchHit(S, -4.6984631, 1.7101007, 0.1, Hit) = chkEntity),
      'curve trim: arc-to-circle keeps the correct curved side');
  finally
    S.Free;
  end;

  S := TCADSketch.Create;
  try
    Arc := S.AddArc(S.AddPoint(0, 0), S.AddPoint(5, 0), S.AddPoint(-5, 0));
    S.AddArc(S.AddPoint(6, 0), S.AddPoint(11, 0), S.AddPoint(1, 0));
    Check(CADPlanSketchTrim(S, Arc, 4.6984631, 1.7101007, Plan, Err) and
      CADApplySketchTrim(S, Plan, Err),
      'curve trim: arc-arc real intersection removes clicked section');
  finally
    S.Free;
  end;
end;

procedure TestLineTrimmedByCircle;
var
  S: TCADSketch;
  Line, Hit, LeftPiece, RightPiece: Integer;
  Plan: TCADTrimPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Line := S.AddLineXY(-10, 0, 10, 0);
    S.AddCircle(S.AddPoint(0, 0), 5);
    Check(CADPlanSketchTrim(S, Line, 1, 0, Plan, Err) and
      Near(Plan.FromT, 0.25) and Near(Plan.ToT, 0.75),
      'curve trim: line target sees both intersections against a circle');
    Check(CADApplySketchTrim(S, Plan, Err),
      'curve trim: remove middle of line crossed by a circle');
    LeftPiece := S.EntityCount - 2;
    RightPiece := S.EntityCount - 1;
    Check(S.Entities[LeftPiece].Active and S.Entities[RightPiece].Active and
      Near(S.PointX(S.Entities[LeftPiece].P2), -5) and
      Near(S.PointX(S.Entities[RightPiece].P1), 5),
      'curve trim: line now has two real pieces outside the circle');
    { The circle center point is selectable; test away from its centre. }
    Check(CADSketchHit(S, 2, 0, 0.1, Hit) = chkNone,
      'curve trim: removed part of line is not pickable');
  finally
    S.Free;
  end;
end;

procedure TestRadiusAndConstraintGuard;
var
  S: TCADSketch;
  Circle, Other, I: Integer;
  Plan: TCADTrimPlan;
  Err, Before: string;
  RadiusFound: Boolean;
begin
  S := TCADSketch.Create;
  try
    Circle := S.AddCircle(S.AddPoint(0, 0), 5);
    S.Radius(Circle, 5);
    S.AddLineXY(-10, 0, 10, 0);
    Check(CADPlanSketchTrim(S, Circle, 0, 5, Plan, Err) and
      CADApplySketchTrim(S, Plan, Err),
      'curve trim: radius dimension can migrate to surviving arc');
    RadiusFound := False;
    for I := 0 to S.ConstraintCount - 1 do
      if S.Constraints[I].Active and (S.Constraints[I].Kind = sckRadius) and
         (S.Constraints[I].A <> Circle) then
        RadiusFound := True;
    Check(RadiusFound, 'curve trim: remaining arc retains a radius dimension');
  finally
    S.Free;
  end;

  S := TCADSketch.Create;
  try
    Circle := S.AddCircle(S.AddPoint(0, 0), 5);
    Other := S.AddCircle(S.AddPoint(0, 0), 7);
    S.Concentric(Circle, Other);
    S.AddLineXY(-10, 0, 10, 0);
    Before := CADSketchToText(S);
    Check(CADPlanSketchTrim(S, Circle, 0, 5, Plan, Err) and
      not CADApplySketchTrim(S, Plan, Err) and
      (Before = CADSketchToText(S)),
      'curve trim: unsupported concentric relation refuses without mutation');
  finally
    S.Free;
  end;
end;

procedure TestCircleWithOneCrossing;
var
  S: TCADSketch;
  Circle: Integer;
  Plan: TCADTrimPlan;
  Err: string;
begin
  S := TCADSketch.Create;
  try
    Circle := S.AddCircle(S.AddPoint(0, 0), 5);
    S.AddLineXY(0, 5, 0, 10);          { tangent line: only one crossing }
    Check(not CADPlanSketchTrim(S, Circle, 5, 0, Plan, Err) and (Err <> ''),
      'curve trim: a single tangent touch cannot define a circular cut');
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
  TestOldSketchFormatStillLoads;
  TestCircleCutByLine;
  TestCircleCutWithManyCrossings;
  TestCircleCircleIntersection;
  TestArcCutByLine;
  TestArcCutByCircleAndArc;
  TestLineTrimmedByCircle;
  TestRadiusAndConstraintGuard;
  TestCircleWithOneCrossing;
  if Failures = 0 then
    WriteLn(Format('PASS  trim/extend planning: %d checks', [Checks]))
  else
    WriteLn(Format('FAIL  trim/extend planning: %d of %d checks failed',
      [Failures, Checks]));
  if Failures > 0 then Halt(1);
end.
