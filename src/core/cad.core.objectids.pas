unit CAD.Core.ObjectIds;
{$mode objfpc}{$H+}

{ Independent persistent CAD object identifiers. Existing TCADId remains
  reserved for feature slots. Zero is invalid; IDs are never recycled. }
interface

type
  TCADObjectId = record
    Value: QWord;
  end;

  TCADObjectKind = (cokPart, cokOrigin, cokDatumPlane, cokSketch, cokBody);

  TCADObjectRef = record
    Kind: TCADObjectKind;
    Id: TCADObjectId;
  end;

function CADObjectId(AValue: QWord): TCADObjectId;
function CADNoObjectId: TCADObjectId;
function CADObjectIdValid(const AId: TCADObjectId): Boolean;
function CADSameObjectId(const A, B: TCADObjectId): Boolean;
function CADObjectRef(AKind: TCADObjectKind;
  const AId: TCADObjectId): TCADObjectRef;

implementation

function CADObjectId(AValue: QWord): TCADObjectId;
begin
  Result.Value := AValue;
end;

function CADNoObjectId: TCADObjectId;
begin
  Result.Value := 0;
end;

function CADObjectIdValid(const AId: TCADObjectId): Boolean;
begin
  Result := AId.Value <> 0;
end;

function CADSameObjectId(const A, B: TCADObjectId): Boolean;
begin
  Result := A.Value = B.Value;
end;

function CADObjectRef(AKind: TCADObjectKind;
  const AId: TCADObjectId): TCADObjectRef;
begin
  Result.Kind := AKind;
  Result.Id := AId;
end;

end.
