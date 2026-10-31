unit CAD.Core.Values;
{$mode objfpc}{$H+}

{ ROLE:      typed parameter values (length, count, flag, name) and their hash.
  CALLED BY: TCADFeature (parameters), commands (old/new values), cache keys.
  CALLS:     CAD.Core.Ids (hash helpers).
  THREADS:   plain records, any thread.
  SPEED:     a record, no object per value; the hash covers kind + value so
             1 (int) and 1.0 (float) never share a cache key. }

interface

uses
  SysUtils, CAD.Core.Ids;

type
  TCADValueKind = (cvkNone, cvkFloat, cvkInt, cvkBool, cvkText);

  TCADValue = record
    Kind: TCADValueKind;
    F: Double;
    I: Int64;
    B: Boolean;
    S: string;
  end;

  TCADParam = record
    Name: string;
    Value: TCADValue;
  end;

  TCADParamArray = array of TCADParam;

function CADFloat(AValue: Double): TCADValue;
function CADInt(AValue: Int64): TCADValue;
function CADBool(AValue: Boolean): TCADValue;
function CADText(const AValue: string): TCADValue;
function CADNone: TCADValue;
function CADValueEqual(const A, B: TCADValue): Boolean;
function CADValueHash(AHash: TCADHash; const AValue: TCADValue): TCADHash;
function CADValueToString(const AValue: TCADValue): string;

implementation

function Blank(AKind: TCADValueKind): TCADValue;
begin
  Result.Kind := AKind;
  Result.F := 0;
  Result.I := 0;
  Result.B := False;
  Result.S := '';
end;

function CADFloat(AValue: Double): TCADValue;
begin
  Result := Blank(cvkFloat);
  Result.F := AValue;
end;

function CADInt(AValue: Int64): TCADValue;
begin
  Result := Blank(cvkInt);
  Result.I := AValue;
end;

function CADBool(AValue: Boolean): TCADValue;
begin
  Result := Blank(cvkBool);
  Result.B := AValue;
end;

function CADText(const AValue: string): TCADValue;
begin
  Result := Blank(cvkText);
  Result.S := AValue;
end;

function CADNone: TCADValue;
begin
  Result := Blank(cvkNone);
end;

function CADValueEqual(const A, B: TCADValue): Boolean;
begin
  if A.Kind <> B.Kind then
    Exit(False);
  case A.Kind of
    cvkFloat: Result := A.F = B.F;
    cvkInt: Result := A.I = B.I;
    cvkBool: Result := A.B = B.B;
    cvkText: Result := A.S = B.S;
  else
    Result := True;
  end;
end;

function CADValueHash(AHash: TCADHash; const AValue: TCADValue): TCADHash;
begin
  Result := CADHashQWord(AHash, QWord(Ord(AValue.Kind)));
  case AValue.Kind of
    cvkFloat: Result := CADHashDouble(Result, AValue.F);
    cvkInt: Result := CADHashQWord(Result, QWord(AValue.I));
    cvkBool: Result := CADHashQWord(Result, QWord(Ord(AValue.B)));
    cvkText: Result := CADHashString(Result, AValue.S);
  end;
end;

function CADValueToString(const AValue: TCADValue): string;
begin
  case AValue.Kind of
    cvkFloat: Result := FloatToStr(AValue.F);
    cvkInt: Result := IntToStr(AValue.I);
    cvkBool: Result := BoolToStr(AValue.B, True);
    cvkText: Result := AValue.S;
  else
    Result := '';
  end;
end;

end.
