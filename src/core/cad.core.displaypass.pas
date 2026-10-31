unit CAD.Core.DisplayPass;
{$mode objfpc}{$H+}

{ ROLE:      after a recompute, makes display data (meshes) only for the
             results that are shown, never for intermediate ones.
             Example: a plate with 6 holes in a row = 6 boolean results,
             only the last one is drawn -> 1 mesh instead of 6.
  CALLED BY: TCADDocument.PrepareDisplay (end of Recompute when
             Mesh.Timing = cmtDisplayed, or the caller when cmtManual).
  CALLS:     TCADResult.DisplayReady / PrepareDisplay (OCCT: BRepMesh),
             TCADResultCache.Remeasure, TCADDependencyGraph.UserCount.
  THREADS:   calling thread only, after every recompute level finished, so
             no worker reads or writes a result now. Serial on purpose: the
             OCCT bridge meshes under an exclusive lock (results share faces)
             and each mesh already uses all cores (Mesh.InParallel).
  SPEED:     one cheap flag check per feature + one mesh per shown result
             that has none yet. A result from the cache (Undo, drag back)
             keeps its mesh: DisplayReady = True, no remesh. }

interface

uses
  SysUtils, CAD.Core.Feature, CAD.Core.Graph, CAD.Core.ResultCache;

type
  TCADDisplayReport = record
    Shown: Integer;          { features whose result is drawn }
    Prepared: Integer;       { meshes made now (the real cost) }
    Failed: Integer;         { PrepareDisplay failed; see Feature.DisplayError }
    Milliseconds: QWord;
  end;

{ Shown in the viewport? AUserCount = features that use this one. }
function CADIsShown(AFeature: TCADFeature; AUserCount: Integer): Boolean;

{ ASlots[i] = feature in slot i (nil = removed), slots 0..ACount-1 used. }
function RunDisplayPass(const ASlots: array of TCADFeature; ACount: Integer;
  AGraph: TCADDependencyGraph; ACache: TCADResultCache): TCADDisplayReport;

implementation

function CADIsShown(AFeature: TCADFeature; AUserCount: Integer): Boolean;
begin
  case AFeature.ShowMode of
    csmShow: Result := True;
    csmHide: Result := False;
  else
    Result := AUserCount = 0;   { auto: the end of a chain }
  end;
end;

function RunDisplayPass(const ASlots: array of TCADFeature; ACount: Integer;
  AGraph: TCADDependencyGraph; ACache: TCADResultCache): TCADDisplayReport;
var
  Slot: Integer;
  F: TCADFeature;
  Err: string;
  T0: QWord;
begin
  T0 := GetTickCount64;
  FillChar(Result, SizeOf(Result), 0);
  { A full scan, not only the dirty features: an unchanged feature becomes
    the end of a chain when its user is removed, and must be meshed then.
    The scan is a few pointer checks per feature - nothing next to a mesh. }
  for Slot := 0 to ACount - 1 do
  begin
    F := ASlots[Slot];
    if (F = nil) or (F.State <> cfsClean) or (F.Output = nil) then
      Continue;                                   { nothing valid to draw }
    if not CADIsShown(F, AGraph.UserCount(Slot)) then
      Continue;
    Inc(Result.Shown);
    if F.Output.DisplayReady then
    begin
      F.SetDisplayError('');                      { meshed before (or cache) }
      Continue;
    end;
    if F.Output.PrepareDisplay(Err) then
    begin
      F.SetDisplayError('');
      ACache.Remeasure(F.Output);                 { the mesh adds memory }
      Inc(Result.Prepared);
    end
    else
    begin
      F.SetDisplayError(Err);
      Inc(Result.Failed);
    end;
  end;
  Result.Milliseconds := GetTickCount64 - T0;
end;

end.
