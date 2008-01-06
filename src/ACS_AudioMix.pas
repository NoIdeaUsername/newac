(*
  This file is a part of New Audio Components package 1.2
  Copyright (c) 2002-2007 Andrei Borovsky. All rights reserved.
  See the LICENSE file for more details.
  You can contact me at anb@symmetrica.net
*)

(* $Revision: 1.8 $ $Date: 2007/11/26 20:56:26 $ *)

unit ACS_AudioMix;

(* Title: ACS_AudioMix
    Classes that mix audio. *)

interface

uses
  Classes, SysUtils, ACS_Types, ACS_Classes, SyncObjs, Math;

const
  BUF_SIZE = $10000;

type

  TAudioMixerMode = (amMix, amConcatenate, amRTMix, amCustomMix);

  TAudioMixer = class(TAuInput)
  private
    FInput1, FInput2 : TAuInput;
    BufStart, BufEnd : Integer;
    ByteCount : Cardinal;                // add by leozhang
    FVolume1, FVolume2 : Byte;
    EndOfInput1, EndOfInput2 : Boolean;
    InBuf1, InBuf2 : array[1..BUF_SIZE] of Byte;
    Busy : Boolean;
    FMode : TAudioMixerMode;
    FInput2Start: Cardinal;
    CS : TCriticalSection;
    FFgPlaying : Boolean;
    FNormalize : Boolean;
    function GetBPS : Integer; override;
    function GetCh : Integer; override;
    function GetSR : Integer; override;
    procedure SetInput1(aInput : TAuInput);
    procedure SetInput2(aInput : TAuInput);
    procedure GetDataInternal(var Buffer : Pointer; var Bytes : Integer); override;
    procedure InitInternal; override;
    procedure FlushInternal; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property FgPlaying : Boolean read FFgPlaying;
    property Normalize : Boolean read FNormalize write FNormalize;
  published
    property Input1 : TAuInput read FInput1 write SetInput1;
    property Input2 : TAuInput read FInput2 write SetInput2;
    property Mode : TAudioMixerMode read FMode write FMode;
    property Input2Start :Cardinal read FInput2Start write FInput2Start;
    property Volume1 : Byte read FVolume1 write FVolume1;
    property Volume2 : Byte read FVolume2 write FVolume2;
  end;

implementation

procedure MixChannels(Buf1, Buf2 : Pointer; Vol1, Vol2, InSize, BPS : Integer; Norm : Boolean);
var
  i : Integer;
  V1, V2, BUF : Double;
  Buf16_1, Buf16_2 : PBuffer16;
  S1, S2 : Integer;
  Buf8_1, Buf8_2 : PBuffer8;
  BE : Extended;
begin
  if (Vol1 + Vol2) <> 0 then
  begin
    V1 := Vol1 / (Vol1 + Vol2);
    V2 := Vol2 / (Vol1 + Vol2);
  end else
  begin
    V1 := 0;
    V2 := 0;
  end;
  if BPS = 16 then
  begin
    Buf16_1 := Buf1;
    Buf16_2 := Buf2;
    for i := 0 to (Insize shr 1) -1  do
    begin
      BUF := (Buf16_1[i]*V1 + Buf16_2[i]*V2);
      //if Norm then BUF := BUF * N;
      Buf16_2[i] := Floor(BUF);
    end;
  end else
  if BPS = 8 then
  begin
    Buf8_1 := Buf1;
    Buf8_2 := Buf2;
    for i := 0 to Insize - 1 do
    begin
      BUF := (Buf8_1[i]*V1 + Buf8_2[i]*V2);
      //if Norm then BUF := BUF * N;
      Buf8_2[i] := Floor(BUF);
    end;
  end else
  if BPS = 24 then
  begin
    Buf8_1 := Buf1;
    Buf8_2 := Buf2;
    for i := 0 to (Insize div 3) - 1 do
    begin
      S1 := (PSmallInt(@Buf8_1[i*3 + 1])^ shl 8) + Buf8_1[i*3];
      S2 := (PSmallInt(@Buf8_2[i*3 + 1])^ shl 8) + Buf8_2[i*3];
      BE:= (S1*V1 + S2*V2);
      //if Norm then BE := BE * N;
      S1 := Floor(BE);
      Move(S1, Buf8_2[i*3], 3);
    end;
  end;
end;

constructor TAudioMixer.Create;
begin
  inherited Create(AOwner);
  FVolume1 := 255;
  FVolume2 := 255;
  FInput2Start := 0;
  CS := TCriticalSection.Create;
end;

  destructor TAudioMixer.Destroy;
  begin
    CS.Free;
    inherited Destroy;
  end;

  function TAudioMixer.GetBPS;
  begin
    if not Assigned(FInput1) then
    raise EAuException.Create('Input not assigned');
    Result := FInput1.BitsPerSample;
  end;

  function TAudioMixer.GetCh;
  begin
    if not Assigned(FInput1) then
    raise EAuException.Create('Input not assigned');
    Result:= FInput1.Channels;
  end;

  function TAudioMixer.GetSR;
  begin
    if not Assigned(FInput1) then
    raise EAuException.Create('Input not assigned');
    Result := FInput1.SampleRate;
  end;

  procedure TAudioMixer.InitInternal;
  var
    In2StartByte : Cardinal;     // add by zhangl.
  begin
    Busy := True;
    FPosition := 0;
    BufStart := 1;
    BufEnd := 0;
    EndOfInput1 := False;
    EndOfInput2 := False;
    if not Assigned(FInput1) then
    raise EAuException.Create('Input1 not assigned');
    if FMode = amRTMix then
    begin
      FInput1.Init;
      FSize := FInput1.Size;
      if Assigned(FInput2) then
      begin
        FInput2.Init;
        FFgPlaying := True;
      end else EndOfInput2 := True;
    end else
    begin
      if not Assigned(FInput2) then
      raise EAuException.Create('Input2 not assigned');
      FInput1.Init;
      FInput2.Init;
      case FMode of
        amMix :
          if FInput1.Size > FInput2.Size then FSize := FInput1.Size
          else FSize := FInput2.Size;
          amConcatenate :
          FSize := FInput1.Size + FInput2.Size;     //determine the size of the output stream in bytes
          amCustomMix:
          // add by leozhang
          begin
             In2StartByte :=  Round(Int((FInput2Start * FInput2.SampleRate) /1000) *
                              (FInput2.Channels) * ((FInput2.BitsPerSample) shr 3));
             ByteCount := In2StartByte;
             if Cardinal(FInput1.Size) > In2StartByte + FInput2.Size then
                  FSize := FInput1.Size
             else
                  FSize := In2StartByte + FInput2.Size;
          end;
         // leozhang
      end;
    end;
  end;

  procedure TAudioMixer.FlushInternal;
  begin
    FInput1.Flush;
    if (FMode <> amRTMix) or Assigned(FInput2) then
    FInput2.Flush;
    Busy := False;
  end;

  procedure TAudioMixer.GetDataInternal;
  var
    l1, l2 : Integer;
    InSize, Aligned : Integer;
  begin
    Aligned := BUF_SIZE - (BUF_SIZE mod (Channels * (BitsPerSample div 8)));
    if not Busy then  raise EAuException.Create('The Stream is not opened');
    if BufStart > BufEnd then
    begin
      if EndOfInput1 and  EndOfInput2 then
      begin
        Buffer := nil;
        Bytes := 0;
        Exit;
      end;
      if (FMode = amRTMix) and  EndOfInput1 then
      begin
        Buffer := nil;
        Bytes := 0;
        Exit;
      end;
      BufStart := 1;
      case Mode of
        amMix :
        begin
          l1 := 0;
          l2 := 0;
          if Finput1.BitsPerSample = 16 then
          begin
            FillChar(InBuf1[1], Aligned, 0);
            FillChar(InBuf2[1], Aligned, 0);
          end else
          if Finput1.BitsPerSample = 8 then
          begin
            FillChar(InBuf1[1], Aligned, 127);
            FillChar(InBuf2[1], Aligned, 127);
          end;
          if not EndOfInput1 then
          begin
            l1 := FInput1.CopyData(@InBuf1[1], Aligned);
            InSize := l1;
            while (InSize <> 0) and (l1 < Aligned) do
            begin
              InSize := FInput1.CopyData(@InBuf1[l1+1], Aligned - l1);
              Inc(l1, InSize);
            end;
            if InSize = 0 then EndOfInput1 := True;
          end;
          if not EndOfInput2 then
          begin
            l2 := FInput2.CopyData(@InBuf2[1], Aligned);
            InSize := l2;
            while (InSize <> 0) and (l2 < Aligned) do
            begin
              InSize := FInput2.CopyData(@InBuf2[l2+1], Aligned - l2);
              Inc(l2, InSize);
            end;
            if InSize = 0 then EndOfInput2 := True;
          end;
          if (l1 = 0) and (l2 = 0) then
          begin
            Buffer := nil;
            Bytes := 0;
            Exit;
          end;
          if l1 > l2 then BufEnd := l1 else BufEnd := l2;
          MixChannels(@InBuf1[1], @InBuf2[1], FVolume1, FVolume2, BufEnd,
            FInput1.BitsPerSample, FNormalize);
        end;
        amConcatenate :
        begin
          if not EndOfInput1 then
          begin
            l1 := FInput1.CopyData(@InBuf2[1], Aligned);
            if l1 = 0 then EndOfInput1 := True
            else BufEnd := l1;
          end;
          if EndOfInput1 then
          begin
            l2 := FInput2.CopyData(@InBuf2[1], Aligned);
            if l2 = 0 then
            begin
              Buffer := nil;
              Bytes := 0;
              Exit;
            end
            else BufEnd := l2;
          end;
        end;
        // add by leo.zhang
        amCustomMix:
        begin
          l1 := 0;
          l2 := 0;
          FillChar(InBuf1[1], Aligned, 0);
          FillChar(InBuf2[1], Aligned, 0);
          if not EndOfInput1 then
          begin
            l1 := FInput1.CopyData(@InBuf1[1], Aligned);
            InSize := l1;
            while (InSize <> 0) and (l1 < BUF_SIZE) do
            begin
              InSize := FInput1.CopyData(@InBuf1[l1+1], Aligned - l1);
              Inc(l1, InSize);
            end;
            if InSize = 0 then EndOfInput1 := True;
          end;
          CS.Enter;
          if not EndOfInput2 then
          begin
             if ByteCount > Aligned then
             begin
                ByteCount := ByteCount - Aligned;
                l2 := BUF_SIZE; InSize := l2;
             end else
             begin
                  l2 := FInput2.CopyData(@InBuf2[ByteCount+1],Aligned - ByteCount);
                  InSize := l2;
                  if ByteCount <> 0 then
                  begin
                    Inc(l2,ByteCount);
                    InSize := l2;
                    ByteCount := 0;
                  end;
                  while (InSize <> 0) and (l2 < Aligned) do
                  begin
                     InSize := FInput2.CopyData(@InBuf2[l2+1], Aligned - l2);
                     Inc(l2, InSize);
                  end;
             end;
             if InSize = 0 then EndOfInput2 := True;
          end;
          CS.Leave;
          if (l1 = 0) and (l2 = 0) then
          begin
            Buffer := nil;
            Bytes := 0;
            Exit;
          end;
          if l1 > l2 then BufEnd := l1 else BufEnd := l2;
          MixChannels(@InBuf1[1], @InBuf2[1], FVolume1, FVolume2, BufEnd,
          FInput1.BitsPerSample, FNormalize);
        end;
        // leo.zhang.
        amRTMix :
        begin
          l1 := 0;
          l2 := 0;
          FillChar(InBuf1[1], BUF_SIZE, 0);
          FillChar(InBuf2[1], BUF_SIZE, 0);
          if not EndOfInput1 then
          begin
            l1 := FInput1.CopyData(@InBuf1[1], BUF_SIZE);
            InSize := l1;
            while (InSize <> 0) and (l1 < BUF_SIZE) do
            begin
              InSize := FInput1.CopyData(@InBuf1[l1+1], BUF_SIZE - l1);
              Inc(l1, InSize);
            end;
            if InSize = 0 then EndOfInput1 := True;
          end;
          CS.Enter;
          if not EndOfInput2 then
          begin
            l2 := FInput2.CopyData(@InBuf2[1], BUF_SIZE);
            InSize := l2;
            while (InSize <> 0) and (l2 < BUF_SIZE) do
            begin
              InSize := FInput2.CopyData(@InBuf2[l2+1], BUF_SIZE - l2);
              Inc(l2, InSize);
            end;
            if InSize = 0 then
            begin
              EndOfInput2 := True;
              FFGPlaying := False;
              FInput2.Flush;
              FInput2 := nil;
            end;
          end;
          CS.Leave;
          if (l1 = 0) and (l2 = 0) then
          begin
            Buffer := nil;
            Bytes := 0;
            Exit;
          end;
          if l1 > l2 then BufEnd := l1 else BufEnd := l2;
          MixChannels(@InBuf1[1], @InBuf2[1], FVolume1, FVolume2, BufEnd,
          FInput1.BitsPerSample, FNormalize);
        end;
      end;       // case end.
    end;  // endif.
    if Bytes > (BufEnd - BufStart + 1) then
      Bytes := BufEnd - BufStart + 1;
    Buffer := @InBuf2[BufStart];
    Inc(BufStart, Bytes);
    Inc(FPosition, Bytes);
  end;

  procedure TAudioMixer.SetInput1;
  begin
    if Busy then
    raise EAuException.Create('The component is buisy.');
    FInput1 := aInput;
  end;

  procedure TAudioMixer.SetInput2;
  begin
    if not Busy then  FInput2 := aInput
    else
    if (FMode = amRTMix) or (FMode = amCustomMix) then
    begin
      CS.Enter;
      if FFgPlaying then
        Input2.Flush;
      FInput2 := aInput;
      Finput2.Init;
      FFgPlaying := True;
      EndOfInput2 := False;
      CS.Leave;
    end else
    raise EAuException.Create('The component is not in amFB mode.');
  end;

end.