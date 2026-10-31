unit CAD.Sketch.ExtrudeOptions;
{$mode objfpc}{$H+}

{ ROLE: UI-independent numeric validation for a sketch Extrude.
  The exact same settings are used for preview and the saved feature.
  No OCCT or OpenGL dependency, so headless FPC tests can run. }

interface

uses SysUtils, Math;

type
  TCADExtrudeOptions = record
    Depth: Double;                    { positive depth, millimetres }
    Symmetric: Boolean;               { half-depth to either side }
    Reversed: Boolean;                { extrude against the sketch normal }
  end;

function CADDefaultExtrudeOptions: TCADExtrudeOptions;
function CADValidateExtrudeOptions(const AOptions: TCADExtrudeOptions;
  out AError: string): Boolean;
function CADParseExtrudeDepth(const AText: string; out ADepth: Double): Boolean;

implementation

function CADDefaultExtrudeOptions: TCADExtrudeOptions;
begin
  Result.Depth := 10;
  Result.Symmetric := False;
  Result.Reversed := False;
end;

function CADValidateExtrudeOptions(const AOptions: TCADExtrudeOptions;
  out AError: string): Boolean;
begin
  AError := '';
  Result := False;
  if IsNan(AOptions.Depth) or IsInfinite(AOptions.Depth) then
    AError := 'Extrude depth must be a finite number'
  else if AOptions.Depth <= 0 then
    AError := 'Extrude depth must be greater than 0 mm'
  else if AOptions.Depth > 1000000 then
    AError := 'Extrude depth exceeds the 1,000,000 mm safety limit'
  else
    Result := True;
end;

function CADParseExtrudeDepth(const AText: string; out ADepth: Double): Boolean;
var
  S: string;
  F: TFormatSettings;
begin
  S := Trim(AText);
  F := DefaultFormatSettings;
  F.DecimalSeparator := '.';
  Result := TryStrToFloat(S, ADepth, F);
  if not Result then
  begin
    F.DecimalSeparator := ',';
    Result := TryStrToFloat(S, ADepth, F);
  end;
  if not Result then Exit;
  Result := (not IsNan(ADepth)) and (not IsInfinite(ADepth)) and
            (ADepth > 0) and (ADepth <= 1000000);
end;

end.
