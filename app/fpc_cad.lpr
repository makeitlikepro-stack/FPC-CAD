program fpc_cad;
{$mode objfpc}{$H+}

{ FPC-CAD application (stage 4 step 3). Build: bash scripts/build_app.sh }

uses
  {$ifdef unix}cthreads,{$endif}
  Interfaces, Forms, CAD.App.MainForm;

begin
  RequireDerivedFormResource := False;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TCADMainForm, CADMainForm);
  Application.Run;
end.
