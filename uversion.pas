unit uversion;

{ The one place the version number lives. The Windows installer reads it from
  here too (see the Makefile), so bump it only in this file. }

{$mode objfpc}{$H+}

interface

const
  TiecookVersion = '1.0.8';

implementation

end.
