unit CAD.Core.FeatureRegistry;
{$mode objfpc}{$H+}

{ ROLE:      type name -> feature class ('Box' -> TCADBoxFeature), so files,
             scripts and the UI create features without knowing their units.
  CALLED BY: feature units (Register in their initialization), file loading
             (stage 6), UI feature menu.
  CALLS:     CAD.Core.Feature.
  THREADS:   register at start-up, read from the UI thread.
  SPEED:     a handful of types; a sorted list keeps lookups at O(log n). }

interface

uses
  Classes, SysUtils, CAD.Core.Feature;

type
  TCADFeatureRegistry = class
  private
    FNames: TStringList;     { sorted, Objects[] = TCADFeatureClass }
    function GetCount: Integer;
    function GetName(AIndex: Integer): string;
  public
    constructor Create;
    destructor Destroy; override;
    { Raises when the name is already taken by another class. }
    procedure Register(AClass: TCADFeatureClass);
    function FindClass(const ATypeName: string): TCADFeatureClass;
    { nil when the type is unknown. }
    function CreateFeature(const ATypeName: string): TCADFeature;
    property Count: Integer read GetCount;
    property Names[AIndex: Integer]: string read GetName;
  end;

{ Process-wide registry used by the feature units. }
function CADFeatures: TCADFeatureRegistry;

implementation

var
  GRegistry: TCADFeatureRegistry = nil;

function CADFeatures: TCADFeatureRegistry;
begin
  if GRegistry = nil then
    GRegistry := TCADFeatureRegistry.Create;
  Result := GRegistry;
end;

constructor TCADFeatureRegistry.Create;
begin
  inherited Create;
  FNames := TStringList.Create;
  FNames.Sorted := True;
  FNames.CaseSensitive := False;
  FNames.Duplicates := dupError;
end;

destructor TCADFeatureRegistry.Destroy;
begin
  FNames.Free;
  inherited Destroy;
end;

function TCADFeatureRegistry.GetCount: Integer;
begin
  Result := FNames.Count;
end;

function TCADFeatureRegistry.GetName(AIndex: Integer): string;
begin
  Result := FNames[AIndex];
end;

procedure TCADFeatureRegistry.Register(AClass: TCADFeatureClass);
var
  I: Integer;
begin
  I := FNames.IndexOf(AClass.TypeName);
  if I >= 0 then
  begin
    if TCADFeatureClass(Pointer(FNames.Objects[I])) = AClass then
      Exit;
    raise Exception.CreateFmt('Feature type "%s" is already registered', [AClass.TypeName]);
  end;
  FNames.AddObject(AClass.TypeName, TObject(Pointer(AClass)));
end;

function TCADFeatureRegistry.FindClass(const ATypeName: string): TCADFeatureClass;
var
  I: Integer;
begin
  I := FNames.IndexOf(ATypeName);
  if I < 0 then
    Exit(nil);
  Result := TCADFeatureClass(Pointer(FNames.Objects[I]));
end;

function TCADFeatureRegistry.CreateFeature(const ATypeName: string): TCADFeature;
var
  C: TCADFeatureClass;
begin
  C := FindClass(ATypeName);
  if C = nil then
    Exit(nil);
  Result := C.Create;
end;

finalization
  FreeAndNil(GRegistry);
end.
