unit CAD.OCCT.Options;
{$mode objfpc}{$H+}
{$PACKRECORDS C}   { same layout as external/occt_bridge/occt_bridge_options.h }

{ ROLE:      the C record of the bridge options and its conversion from
             TCADPerformanceOptions (the one place all knobs live).
  CALLED BY: TOCCTLibrary.ApplyOptions.
  CALLS:     CAD.Config.Performance.
  THREADS:   pure, any thread.
  SPEED:     n/a (a copy of a few fields). The ABI check (struct_size,
             version) catches a Pascal/C mismatch before any OCCT call. }

interface

uses
  CAD.Config.Performance;

const
  OCCT_BRIDGE_OPTIONS_VERSION = 1;

type
  { Field order and types must match occt_bridge_options.h exactly:
    two int32, four doubles, twelve int32 = 88 bytes. }
  TOCCTBridgeOptions = record
    StructSize: LongInt;
    Version: LongInt;
    MeshLinearDeflection: Double;
    MeshAngularDeflectionDeg: Double;
    MeshMinSize: Double;
    BoolFuzzyValue: Double;
    MeshInParallel: LongInt;
    MeshRelative: LongInt;
    MeshControlSurfaceDeflection: LongInt;
    MeshAllowQualityDecrease: LongInt;
    MeshKeepExisting: LongInt;
    BoolRunParallel: LongInt;
    BoolUseOBB: LongInt;
    BoolGlue: LongInt;
    BoolNonDestructive: LongInt;
    BoolCheckInverted: LongInt;
    OcctThreads: LongInt;
    Reserved: LongInt;
  end;

const
  OCCT_BRIDGE_OPTIONS_SIZE = 88;

function OCCTOptionsFromPerformance(const AOptions: TCADPerformanceOptions): TOCCTBridgeOptions;

implementation

function B(AValue: Boolean): LongInt;
begin
  if AValue then Result := 1 else Result := 0;
end;

function OCCTOptionsFromPerformance(const AOptions: TCADPerformanceOptions): TOCCTBridgeOptions;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.StructSize := SizeOf(TOCCTBridgeOptions);
  Result.Version := OCCT_BRIDGE_OPTIONS_VERSION;
  with AOptions.Mesh do
  begin
    Result.MeshLinearDeflection := LinearDeflection;
    Result.MeshAngularDeflectionDeg := AngularDeflectionDeg;
    Result.MeshMinSize := MinSize;
    Result.MeshInParallel := B(InParallel);
    Result.MeshRelative := B(Relative);
    Result.MeshControlSurfaceDeflection := B(ControlSurfaceDeflection);
    Result.MeshAllowQualityDecrease := B(AllowQualityDecrease);
    Result.MeshKeepExisting := B(KeepExistingTriangulation);
  end;
  with AOptions.Booleans do
  begin
    Result.BoolFuzzyValue := FuzzyValue;
    Result.BoolRunParallel := B(RunParallel);
    Result.BoolUseOBB := B(UseOBB);
    Result.BoolGlue := Ord(Glue);          { cgmOff=0, cgmShift=1, cgmFull=2 }
    Result.BoolNonDestructive := B(NonDestructive);
    Result.BoolCheckInverted := B(CheckInverted);
  end;
  Result.OcctThreads := AOptions.Threads.OcctThreads;
end;

end.
