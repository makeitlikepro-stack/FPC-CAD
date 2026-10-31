program fpc_cad;
{$mode objfpc}{$H+}
{$codepage utf8}

{ FPC-CAD application. Build: bash scripts/build_app.sh, or open
  app/fpc_cad.lpi in FPC Visual IDE (main window: app/MainForm.fvform). }

uses
  {$ifdef unix}cthreads,{$endif}
  Interfaces, Forms, Math, UMainForm;

begin
  { OpenGL drivers raise FP exceptions the RTL would turn into crashes. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
    exOverflow, exUnderflow, exPrecision]);
  RequireDerivedFormResource := False;
  Application.Title := 'FPC-CAD';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
