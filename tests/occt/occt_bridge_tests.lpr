program occt_bridge_tests;
{$mode objfpc}{$H+}

{ Native tests of the OCCT bridge (needs OCCT and a built bridge).
  Run: bash scripts/test_occt.sh
  1. ABI: Pascal record = C struct (size, offsets), options mapping.
  2. Bridge: load, options round trip, ABI mismatch rejected.
  3. Geometry: prism volume, cut volume, mesh and B-rep edges exist.
  4. Speed (INFO): meshing with InParallel off / on. }

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Math, CAD.Config.Performance, CAD.OCCT.Options, CAD.OCCT.Library;

var
  Checks, Failures: Integer;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(Checks);
  if not ACondition then
  begin
    Inc(Failures);
    WriteLn('FAIL  ', AName);
  end;
end;

procedure TestAbi;
var
  O: TOCCTBridgeOptions;
  P: TCADPerformanceOptions;
  Base: PtrUInt;
begin
  Check(SizeOf(TOCCTBridgeOptions) = OCCT_BRIDGE_OPTIONS_SIZE, 'Pascal record is 88 bytes like the C struct');
  Base := PtrUInt(@O);
  Check(PtrUInt(@O.MeshLinearDeflection) - Base = 8, 'first double at offset 8');
  Check(PtrUInt(@O.BoolFuzzyValue) - Base = 32, 'last double at offset 32');
  Check(PtrUInt(@O.MeshInParallel) - Base = 40, 'first int at offset 40');
  Check(PtrUInt(@O.Reserved) - Base = 84, 'last int at offset 84');

  P := DefaultPerformanceOptions;
  P.Booleans.Glue := cgmFull;
  P.Threads.OcctThreads := 3;
  P.Mesh.InParallel := False;
  O := OCCTOptionsFromPerformance(P);
  Check((O.StructSize = 88) and (O.Version = OCCT_BRIDGE_OPTIONS_VERSION), 'header fields');
  Check((O.BoolGlue = 2) and (O.OcctThreads = 3) and (O.MeshInParallel = 0) and
        (O.BoolRunParallel = 1) and (O.BoolUseOBB = 1), 'options mapping');
end;

function TimeMesh(L: TOCCTLibrary; AShape: TOCCTShapeHandle; AParallel: Boolean): QWord;
var
  P: TCADPerformanceOptions;
  M: TOCCTMeshHandle;
  T0: QWord;
  I: Integer;
begin
  P := DefaultPerformanceOptions;
  P.Mesh.InParallel := AParallel;
  P.Mesh.KeepExistingTriangulation := False;   { force a real remesh each time }
  P.Mesh.Relative := False;
  P.Mesh.LinearDeflection := 0.002;
  P.Mesh.AngularDeflectionDeg := 2;
  L.ApplyOptions(P);
  T0 := GetTickCount64;
  for I := 1 to 5 do
  begin
    M := L.MeshShape(AShape, 0);
    L.FreeMesh(M);
  end;
  Result := GetTickCount64 - T0;
end;

procedure TestBridge;
var
  L: TOCCTLibrary;
  O, Back: TOCCTBridgeOptions;
  Prism, Cut: TOCCTShapeHandle;
  M: TOCCTMeshHandle;
  V: Double;
  TSerial, TParallel: QWord;
begin
  L := TOCCTLibrary.Create;
  try
    try
      L.Load;
    except
      on E: Exception do
      begin
        WriteLn('BLOCKED  ', E.Message);
        Halt(2);
      end;
    end;
    WriteLn('INFO  bridge ', L.Path, ', OCCT ', L.OcctVersion);
    Check(L.BridgeOptionsSize = SizeOf(TOCCTBridgeOptions), 'bridge reports the same struct size');
    Check(L.ApplyOptions(DefaultPerformanceOptions), 'default options accepted');
    O := OCCTOptionsFromPerformance(DefaultPerformanceOptions);
    Check(L.ReadOptions(Back) and CompareMem(@O, @Back, SizeOf(O)), 'options round trip is byte identical');
    O.StructSize := 80;
    Check(not L.SetBridgeOptions(O) and (Pos('mismatch', L.LastError) > 0), 'wrong struct size rejected');

    Prism := L.MakePrism(10, 20, 30);
    Check(Prism <> nil, 'prism created: ' + L.LastError);
    M := L.MeshShape(Prism, 0);
    Check(M <> nil, 'prism meshed: ' + L.LastError);
    if M <> nil then
    begin
      V := L.MeshVolume(M);
      Check(Abs(V - 6000) < 1e-6, Format('prism volume %.6f = 6000', [V]));
      Check((L.MeshVertexCount(M) > 0) and (L.MeshIndexCount(M) mod 3 = 0), 'prism mesh has triangles');
      Check(L.MeshEdgeVertexCount(M) >= 24, 'prism has 12 B-rep edges as line pairs');
      L.FreeMesh(M);
    end;

    Cut := L.CutCylinder(Prism, 2, 0, 0);
    Check(Cut <> nil, 'cut with options (parallel, OBB, non-destructive): ' + L.LastError);
    M := L.MeshShape(Cut, 0);
    if M <> nil then
    begin
      V := L.MeshVolume(M);
      Check(Abs(V - (6000 - Pi * 4 * 30)) < 1e-2, Format('cut volume %.4f = 6000 - pi*4*30', [V]));
      L.FreeMesh(M);
    end
    else
      Check(False, 'cut meshed: ' + L.LastError);

    M := L.MeshShape(Prism, 0);
    Check((M <> nil) and (Abs(L.MeshVolume(M) - 6000) < 1e-6), 'non-destructive: the prism is unchanged after the cut');
    L.FreeMesh(M);

    TSerial := TimeMesh(L, Cut, False);
    TParallel := TimeMesh(L, Cut, True);
    WriteLn(Format('INFO  fine mesh x5: InParallel off %d ms, on %d ms', [TSerial, TParallel]));
    L.ApplyOptions(DefaultPerformanceOptions);

    L.FreeShape(Cut);
    L.FreeShape(Prism);
  finally
    L.Free;
  end;
end;

begin
  Checks := 0;
  Failures := 0;
  TestAbi;
  TestBridge;
  if Failures = 0 then
    WriteLn(Format('PASS  occt bridge: %d checks', [Checks]))
  else
    WriteLn(Format('FAIL  occt bridge: %d of %d checks failed', [Failures, Checks]));
  if Failures <> 0 then
    Halt(1);
end.
