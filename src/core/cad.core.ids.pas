unit CAD.Core.Ids;
{$mode objfpc}{$H+}

{ ROLE:      feature handles and the 64-bit hash used for cache keys.
  CALLED BY: every core unit.
  CALLS:     nothing.
  THREADS:   pure functions, any thread.
  SPEED:     an id IS the slot index in the document array: lookup is O(1).
             Slots are never reused, so an id never points to another
             feature, and Undo/Redo can bring a feature back under its id. }

interface

type
  TCADId = record
    Slot: LongInt;          { 0-based slot; -1 = no feature }
  end;

  TCADIdArray = array of TCADId;

  TCADHash = QWord;

const
  CAD_HASH_SEED: TCADHash = TCADHash($CBF29CE484222325);   { FNV-1a offset basis }

function CADId(ASlot: LongInt): TCADId;
function CADNoId: TCADId;
function CADIdValid(const AId: TCADId): Boolean;
function CADIdEqual(const A, B: TCADId): Boolean;

{ FNV-1a, 64 bit. Feed bytes, then combine keys with CADHashCombine. }
function CADHashBytes(AHash: TCADHash; AData: Pointer; ACount: SizeInt): TCADHash;
function CADHashString(AHash: TCADHash; const AText: string): TCADHash;
function CADHashQWord(AHash: TCADHash; AValue: QWord): TCADHash;
function CADHashDouble(AHash: TCADHash; AValue: Double): TCADHash;
function CADHashCombine(AHash, AOther: TCADHash): TCADHash;

implementation

{$Q-}{$R-}   { hashes wrap around on purpose }

const
  FNV_PRIME: QWord = QWord($00000100000001B3);

function CADId(ASlot: LongInt): TCADId;
begin
  Result.Slot := ASlot;
end;

function CADNoId: TCADId;
begin
  Result.Slot := -1;
end;

function CADIdValid(const AId: TCADId): Boolean;
begin
  Result := AId.Slot >= 0;
end;

function CADIdEqual(const A, B: TCADId): Boolean;
begin
  Result := A.Slot = B.Slot;
end;

function CADHashBytes(AHash: TCADHash; AData: Pointer; ACount: SizeInt): TCADHash;
var
  P: PByte;
  I: SizeInt;
begin
  Result := AHash;
  P := PByte(AData);
  for I := 0 to ACount - 1 do
  begin
    Result := (Result xor P[I]) * FNV_PRIME;
  end;
end;

function CADHashString(AHash: TCADHash; const AText: string): TCADHash;
var
  N: SizeInt;
begin
  N := Length(AText);
  { Length first, so 'ab'+'c' and 'a'+'bc' give different keys. }
  Result := CADHashQWord(AHash, QWord(N));
  if N > 0 then
    Result := CADHashBytes(Result, @AText[1], N);
end;

function CADHashQWord(AHash: TCADHash; AValue: QWord): TCADHash;
begin
  Result := CADHashBytes(AHash, @AValue, SizeOf(AValue));
end;

function CADHashDouble(AHash: TCADHash; AValue: Double): TCADHash;
begin
  { -0.0 and 0.0 are the same parameter value. }
  if AValue = 0 then
    AValue := 0;
  Result := CADHashBytes(AHash, @AValue, SizeOf(AValue));
end;

function CADHashCombine(AHash, AOther: TCADHash): TCADHash;
begin
  Result := CADHashQWord(AHash, AOther);
end;

end.
