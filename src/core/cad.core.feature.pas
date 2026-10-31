unit CAD.Core.Feature;
{$mode objfpc}{$H+}

{ ROLE:      base class of every modelling step (box, extrude, boolean ...)
             and base class of its computed result.
  CALLED BY: TCADDocument (owns attached features, calls Compute through
             RunCompute), feature units (derive from TCADFeature).
  CALLS:     CAD.Core.Values (parameters), CAD.Core.Ids (hash).
  THREADS:   parameters change on the UI thread between recomputes.
             RunCompute is called on a worker thread; it may read the inputs'
             results (immutable) and write only this feature's state.
  SPEED:     the parameter hash is cached and rebuilt only after a change;
             the cache key of a recompute costs one hash per input. }

interface

uses
  SysUtils, CAD.Core.Ids, CAD.Core.Values;

type
  { Output of one feature. The model part (shape, value) is immutable once
    stored in the cache: many features and the undo history may share it.
    The cache owns every result.
    Display part (mesh): added later, only for results that are shown, by
    the display pass (CAD.Core.DisplayPass) on the calling thread after all
    recompute levels finished - never while workers run. }
  TCADResult = class
  private
    FKey: TCADHash;
    FUseCount: Integer;       { features holding it; changed under the cache lock }
    FLastUse: QWord;          { cache LRU stamp }
    FAccountedBytes: Int64;   { size the cache counted for it (cache lock) }
  public
    { Rough memory size for the cache limit; override for big results. }
    function EstimatedBytes: Int64; virtual;
    { --- display data (viewport). Default: nothing to prepare. --- }
    { True when the viewport can draw it without more work. }
    function DisplayReady: Boolean; virtual;
    { Makes the display data (OCCT: the mesh). False + AError on failure;
      the model result stays valid. }
    function PrepareDisplay(out AError: string): Boolean; virtual;
    property Key: TCADHash read FKey write FKey;
    property UseCount: Integer read FUseCount write FUseCount;
    property LastUse: QWord read FLastUse write FLastUse;
    property AccountedBytes: Int64 read FAccountedBytes write FAccountedBytes;
  end;

  TCADResultArray = array of TCADResult;

  TCADFeatureState = (
    cfsDirty,     { must be recomputed }
    cfsClean,     { result is valid for the current parameters and inputs }
    cfsFailed,    { Compute returned False or raised; see LastError }
    cfsBlocked    { an input is failed or blocked, Compute was not called }
  );

  { Is the feature's result drawn in the viewport (and so meshed)? }
  TCADShowMode = (
    csmAuto,      { shown when nothing uses it (end of a chain) - default }
    csmShow,      { always shown, e.g. a body the user wants to see mid-tree }
    csmHide       { never shown }
  );

  TCADFeature = class
  private
    FId: TCADId;
    FName: string;
    FParams: TCADParamArray;
    FParamsHash: TCADHash;
    FParamsHashValid: Boolean;
    FInputs: TCADIdArray;     { ordered: Compute receives results in this order }
    FResult: TCADResult;      { not owned (the cache owns it) }
    FState: TCADFeatureState;
    FLastError: string;
    FShowMode: TCADShowMode;
    FDisplayError: string;    { last PrepareDisplay failure ('' = ok) }
    function IndexOfParam(const AName: string): Integer;
    function GetParamCount: Integer;
    function GetParam(AIndex: Integer): TCADParam;
  protected
    { The real work. AInputs are the results of Inputs, in the same order.
      Return a new result (the caller sets its key and stores it) or False
      with AError. Must not touch other features or the document. }
    function Compute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean; virtual; abstract;
    { Declares parameters with default values (called by the constructor). }
    procedure DefineParams; virtual;
    procedure AddParam(const AName: string; const ADefault: TCADValue);
  public
    constructor Create; virtual;
    { Registry name, also part of the cache key ('Box', 'Extrude', ...). }
    class function TypeName: string; virtual; abstract;
    function GetParamValue(const AName: string): TCADValue;
    { Returns False when the parameter does not exist or the kind differs. }
    function SetParamValue(const AName: string; const AValue: TCADValue): Boolean;
    function HasParam(const AName: string): Boolean;
    function ParamsHash: TCADHash;
    { Cache key = type + parameters + keys of the input results. }
    function BuildKey(const AInputs: array of TCADResult): TCADHash;
    { Used by TCADDocument only. }
    procedure SetId(const AId: TCADId);
    procedure SetInputs(const AInputs: TCADIdArray);
    procedure SetState(AState: TCADFeatureState; const AError: string);
    procedure SetResultRef(AResult: TCADResult);
    procedure SetShowMode(AMode: TCADShowMode);
    procedure SetDisplayError(const AError: string);
    function RunCompute(const AInputs: array of TCADResult; out AResult: TCADResult;
      out AError: string): Boolean;
    property Id: TCADId read FId;
    property Name: string read FName write FName;
    property Inputs: TCADIdArray read FInputs;
    { Current result (nil until computed). Named Output, not Result, so it
      never collides with the implicit Result variable of functions. }
    property Output: TCADResult read FResult;
    property State: TCADFeatureState read FState;
    property LastError: string read FLastError;
    { Change it with TCADDocument.SetShowMode (marks the display pass). }
    property ShowMode: TCADShowMode read FShowMode;
    { The model is valid but its mesh failed (State stays cfsClean). }
    property DisplayError: string read FDisplayError;
    property ParamCount: Integer read GetParamCount;
    property Params[AIndex: Integer]: TCADParam read GetParam;
  end;

  TCADFeatureClass = class of TCADFeature;

implementation

function TCADResult.EstimatedBytes: Int64;
begin
  Result := InstanceSize;
end;

function TCADResult.DisplayReady: Boolean;
begin
  Result := True;
end;

function TCADResult.PrepareDisplay(out AError: string): Boolean;
begin
  AError := '';
  Result := True;
end;

constructor TCADFeature.Create;
begin
  inherited Create;
  FId := CADNoId;
  FState := cfsDirty;
  FShowMode := csmAuto;
  DefineParams;
end;

procedure TCADFeature.DefineParams;
begin
  { No parameters by default. }
end;

procedure TCADFeature.AddParam(const AName: string; const ADefault: TCADValue);
var
  N: Integer;
begin
  if IndexOfParam(AName) >= 0 then
    raise Exception.CreateFmt('%s: parameter "%s" defined twice', [TypeName, AName]);
  N := Length(FParams);
  SetLength(FParams, N + 1);
  FParams[N].Name := AName;
  FParams[N].Value := ADefault;
  FParamsHashValid := False;
end;

function TCADFeature.IndexOfParam(const AName: string): Integer;
var
  I: Integer;
begin
  { Features have a handful of parameters: a linear scan beats a map here. }
  for I := 0 to High(FParams) do
    if SameText(FParams[I].Name, AName) then
      Exit(I);
  Result := -1;
end;

function TCADFeature.GetParamCount: Integer;
begin
  Result := Length(FParams);
end;

function TCADFeature.GetParam(AIndex: Integer): TCADParam;
begin
  Result := FParams[AIndex];
end;

function TCADFeature.HasParam(const AName: string): Boolean;
begin
  Result := IndexOfParam(AName) >= 0;
end;

function TCADFeature.GetParamValue(const AName: string): TCADValue;
var
  I: Integer;
begin
  I := IndexOfParam(AName);
  if I < 0 then
    Exit(CADNone);
  Result := FParams[I].Value;
end;

function TCADFeature.SetParamValue(const AName: string; const AValue: TCADValue): Boolean;
var
  I: Integer;
begin
  I := IndexOfParam(AName);
  Result := (I >= 0) and (FParams[I].Value.Kind = AValue.Kind);
  if not Result then
    Exit;
  if CADValueEqual(FParams[I].Value, AValue) then
    Exit;                                  { same value: key stays, nothing dirty }
  FParams[I].Value := AValue;
  FParamsHashValid := False;
end;

function TCADFeature.ParamsHash: TCADHash;
var
  I: Integer;
  H: TCADHash;
begin
  if not FParamsHashValid then
  begin
    H := CADHashString(CAD_HASH_SEED, TypeName);
    for I := 0 to High(FParams) do
    begin
      H := CADHashString(H, LowerCase(FParams[I].Name));
      H := CADValueHash(H, FParams[I].Value);
    end;
    FParamsHash := H;
    FParamsHashValid := True;
  end;
  Result := FParamsHash;
end;

function TCADFeature.BuildKey(const AInputs: array of TCADResult): TCADHash;
var
  I: Integer;
begin
  Result := ParamsHash;
  Result := CADHashQWord(Result, QWord(Length(AInputs)));
  for I := 0 to High(AInputs) do
    Result := CADHashCombine(Result, AInputs[I].Key);
end;

procedure TCADFeature.SetId(const AId: TCADId);
begin
  FId := AId;
end;

procedure TCADFeature.SetInputs(const AInputs: TCADIdArray);
begin
  FInputs := Copy(AInputs);
end;

procedure TCADFeature.SetState(AState: TCADFeatureState; const AError: string);
begin
  FState := AState;
  FLastError := AError;
end;

procedure TCADFeature.SetResultRef(AResult: TCADResult);
begin
  FResult := AResult;
end;

procedure TCADFeature.SetShowMode(AMode: TCADShowMode);
begin
  FShowMode := AMode;
end;

procedure TCADFeature.SetDisplayError(const AError: string);
begin
  FDisplayError := AError;
end;

function TCADFeature.RunCompute(const AInputs: array of TCADResult;
  out AResult: TCADResult; out AError: string): Boolean;
begin
  AResult := nil;
  AError := '';
  try
    Result := Compute(AInputs, AResult, AError);
    if Result and (AResult = nil) then
    begin
      Result := False;
      AError := TypeName + ': Compute returned no result';
    end;
  except
    on E: Exception do
    begin
      { A worker thread must never die from a feature error. }
      FreeAndNil(AResult);
      AError := TypeName + ': ' + E.ClassName + ': ' + E.Message;
      Result := False;
    end;
  end;
  if (not Result) and (AResult <> nil) then
    FreeAndNil(AResult);
end;

end.
