(*
  This file is a part of New Audio Components package v. 1.3
  Copyright (c) 2002-2007, Andrei Borovsky. All rights reserved.
  See the LICENSE file for more details.
  You can contact me at anb@symmetrica.net
*)

(* $Revision: 1.12 $ $Date: 2007/11/26 20:56:26 $ *)

unit ACS_DXAudio;

(* Title: ACS_DXAudio
    Classes which deal with audio data from DirectX. *)

interface

uses
  SysUtils, Classes, Forms, ACS_Types, ACS_Classes, Windows, DSWrapper, _DirectSound;

const

  DS_BUFFER_SIZE = $10000; // Size in frames, not in bytes;
  DS_POLLING_INTERVAL = 200; //milliseconds

type

  TDXAudioOut = class(TAuOutput)
  private
    Freed : Boolean;
    DSW : DSoundWrapper;
    Devices : DSW_Devices;
    Chan, SR, BPS : Integer;
    EndOfInput, StartInput : Boolean;
    Buf : PBuffer8;
    FDeviceNumber : Integer;
    FDeviceCount : Integer;
    _BufSize : Integer;
    FBufferSize : Integer;
    FillByte : Byte;
    FUnderruns, _TmpUnderruns : Integer;
    procedure SetDeviceNumber(i : Integer);
    function GetDeviceName(Number : Integer) : String;
  protected
    procedure Done; override;
    function DoOutput(Abort : Boolean):Boolean; override;
    procedure Prepare; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Pause;
    procedure Resume;
    property DeviceCount : Integer read FDeviceCount;
    property DeviceName[Number : Integer] : String read GetDeviceName;
    property Underruns : Integer read FUnderruns;
    property BufferSize : Integer read FBufferSize write FBufferSize;
  published
    property DeviceNumber : Integer read FDeviceNumber write SetDeviceNumber;
  end;

  TDXAudioIn = class(TAuInput)
  private
    DSW : DSoundWrapper;
    Devices : DSW_Devices;
    _BufSize : Integer;
    Buf : PBuffer8;
    FDeviceNumber : Integer;
    FDeviceCount : Integer;
    FBPS, FChan, FFreq : Integer;
    FOpened : Integer;
    FBytesToRead : Integer;
    FRecTime : Integer;
    FUnderruns : Integer;
    procedure SetDeviceNumber(i : Integer);
    function GetDeviceName(Number : Integer) : String;
    procedure OpenAudio;
    procedure CloseAudio;
    function GetTotalTime : Integer; override;
    procedure SetRecTime(aRecTime : Integer);
  protected
    function GetBPS : Integer; override;
    function GetCh : Integer; override;
    function GetSR : Integer; override;
    procedure GetDataInternal(var Buffer : Pointer; var Bytes : Integer); override;
    procedure InitInternal; override;
    procedure FlushInternal; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure _Pause; override;
    procedure _Resume; override;
    property DeviceCount : Integer read FDeviceCount;
    property DeviceName[Number : Integer] : String read GetDeviceName;
    property Underruns : Integer read FUnderruns;
  published
    property BytesToRead : Integer read FBytesToRead write FBytesToRead;
    property DeviceNumber : Integer read FDeviceNumber write SetDeviceNumber;
    property InBitsPerSample : Integer read GetBPS write FBPS stored True;
    property InChannels : Integer read GetCh write FChan stored True;
    property InSampleRate : Integer read GetSR write FFreq stored True;
    property RecTime : Integer read FRecTime write SetRecTime;
  end;

implementation

function _Min(x1, x2 : Integer) : Integer;
begin
  if x1 < x2 then
    Result := x1
  else
    Result := x2;
end;

procedure TDXAudioOut.Prepare;
var
  Res : HResult;
  Wnd : HWND;
  Form : TForm;
begin
  Freed := False;
  if (FDeviceNumber >= FDeviceCount) then raise EAuException.Create('Invalid device number');
  FInput.Init;
  Chan := FInput.Channels;
  SR := FInput.SampleRate;
  BPS := FInput.BitsPerSample;
  DSW_Init(DSW);
  Res := DSW_InitOutputDevice(DSW, @(Devices.dinfo[FDeviceNumber].guid));
  if Res <> 0 then raise EAuException.Create('Failed to create DirectSound device');
  if Owner is TForm then
  begin
    Form := Owner as TForm;
    Wnd := Form.Handle;
  end else Wnd := 0;
  _BufSize := FBufferSize*(BPS shr 3)*Chan;
  GetMem(Buf, _BufSize);
  if BPS <> 8 then
    FillByte := 0
  else
    FillByte := 128;
  Res := DSW_InitOutputBuffer(DSW, Wnd, BPS, SR, Chan, _BufSize);
  if Res <> 0 then raise EAuException.Create('Failed to create DirectSound buffer');
  StartInput := True;
  EndOfInput := False;
  _TmpUnderruns := 0;
end;

procedure TDXAudioOut.Done;
begin
  Finput.Flush;
  if not Freed then
  begin
    DSW_Term(DSW);
    FreeMem(Buf);
  end;
  Freed := True;
end;

function TDXAudioOut.DoOutput;
var
  Len : Integer;
  lb : Integer;
//  Res : HRESULT;
  PlayTime, CTime : LongWord;
begin
  Result := True;
  if not Busy then Exit;
  if not CanOutput then
  begin
    Result := False;
    Exit;
  end;
  if StartInput then
  begin
    Len := FInput.FillBuffer(Buf, _BufSize, EndOfInput);
    DSW_WriteBlock(DSW, @Buf[0], Len);
    DSW_StartOutput(DSW);
    StartInput := False;
  end;
  if Abort then
  begin
    DSW_StopOutput(DSW);
    CanOutput := False;
    Result := False;
    Exit;
  end;
  if EndOfInput then
  begin
    CanOutput := False;
    PlayTime := Round(_BufSize/(Chan*(BPS div 8)*SR))*1000;
    CTime := 0;
    while CTime < PlayTime do
    begin
      Sleep(100);
      DSW_FillEmptySpace(DSW, FillByte);
      Inc(CTime, 100);
    end;
    DSW_StopOutput(DSW);
    Result := False;
    Exit;
  end;
  Sleep(DS_POLLING_INTERVAL);
  DSW_QueryOutputSpace(DSW, lb);
  lb := lb - (lb mod DSW.dsw_BytesPerFrame);
  Len := FInput.FillBuffer(Buf, _Min(lb, _BufSize), EndOfInput);
  DSW_WriteBlock(DSW, @Buf[0], Len);
  if EndOfInput then
    DSW_FillEmptySpace(DSW, FillByte);
  if _TmpUnderruns <> DSW.dsw_OutputUnderflows then
  begin
    FUnderruns := DSW.dsw_OutputUnderflows - _TmpUnderruns;
    _TmpUnderruns := DSW.dsw_OutputUnderflows;
  end;
end;

constructor TDXAudioOut.Create;
begin
  inherited Create(AOwner);
  FBufferSize := DS_BUFFER_SIZE;
  DSW_EnumerateOutputDevices(@Devices);
  FDeviceCount := Devices.devcount;
end;

destructor TDXAudioOut.Destroy;
begin
  inherited Destroy;
end;

procedure TDXAudioOut.Pause;
begin
  if EndOfInput then Exit;
  DSW_StopOutput(DSW);
  inherited Pause;
end;

procedure TDXAudioOut.Resume;
begin
  if EndOfInput then Exit;
  DSW_RestartOutput(DSW);
  inherited Resume;
end;

procedure TDXAudioOut.SetDeviceNumber(i : Integer);
begin
  FDeviceNumber := i
end;

function TDXAudioOut.GetDeviceName(Number : Integer) : String;
begin
  if (Number < FDeviceCount) then Result := PChar(@(Devices.dinfo[Number].Name[0]))
  else Result := '';
end;

constructor TDXAudioIn.Create;
begin
  inherited Create(AOwner);
  FBPS := 8;
  FChan := 1;
  FFreq := 8000;
  FSize := -1;
//  if not (csDesigning	in ComponentState) then
//  begin
//    if not LibdswLoaded then
//    raise EACSException.Create('Library dswrapper.dll not found');
//  end;
  DSW_EnumerateInputDevices(@Devices);
  FDeviceCount := Devices.devcount;
end;

destructor TDXAudioIn.Destroy;
begin
  DSW_Term(DSW);
  inherited Destroy;
end;

procedure TDXAudioIn.OpenAudio;
var
  Res : HResult;
  S : String;
begin
  if FOpened = 0 then
  begin
    DSW_Init(DSW);
    //if not Assigned(DSW_InitInputDevice) then raise EACSException.Create('Failed');
    Res := DSW_InitInputDevice(DSW, @(Devices.dinfo[FDeviceNumber].guid));
    if Res <> 0 then
    begin
      case res of
        DSERR_ALLOCATED : S := 'DSERR_ALLOCATED';
        DSERR_INVALIDPARAM : S := 'DSERR_INVALIDPARAM';
        DSERR_INVALIDCALL : S := 'DSERR_INVALIDCALL';
        DSERR_GENERIC : S := 'DSERR_GENERIC';
        DSERR_BADFORMAT : S := 'DSERR_BADFORMAT';
        DSERR_UNSUPPORTED : S:= 'DSERR_UNSUPPORTED';
        DSERR_NODRIVER : S := 'DSERR_NODRIVER';
        DSERR_ALREADYINITIALIZED : S := 'DSERR_ALREADYINITIALIZED';
        else S := 'Unknown';
      end;
      raise EAuException.Create('Failed to create DirectSound device: ' + S);
    end;  
    _BufSize := DS_BUFFER_SIZE*(FBPS shr 3)*FChan;
    GetMem(Buf, _BufSize);
    Res := DSW_InitInputBuffer(DSW, FBPS, FFreq, FChan, _BufSize);
    if Res <> 0 then raise EAuException.Create('Failed to create DirectSound buffer');
  end;
  Inc(FOpened);
end;

procedure TDXAudioIn.CloseAudio;
begin
  if FOpened = 1 then
  begin
    DSW_Term(DSW);
    FreeMem(Buf);
  end;
  if FOpened > 0 then Dec(FOpened);
end;

function TDXAudioIn.GetBPS;
begin
  Result := FBPS;
end;

function TDXAudioIn.GetCh;
begin
  Result := FChan;
end;

function TDXAudioIn.GetSR;
begin
  Result := FFreq;
end;

procedure TDXAudioIn.InitInternal;
begin
  if Busy then raise EAuException.Create('The component is busy');
  if (FDeviceNumber >= FDeviceCount) then raise EAuException.Create('Invalid device number');
  if FRecTime > 0 then FBytesToRead := FRecTime*FFreq*FChan*(FBPS div 8);
  BufEnd := 0;
  BufStart := 1;
  FPosition := 0;
  Busy := True;
  FSize := FBytesToRead;
  FSampleSize := FChan*FBPS div 8;
  OpenAudio;
  DSW_StartInput(DSW);
end;

procedure TDXAudioIn.FlushInternal;
begin
  DSW_StopInput(DSW);
  CloseAudio;
  Busy := False;
end;

procedure TDXAudioIn.GetDataInternal;
var
  l : INteger;
begin
  if not Busy then  raise EAuException.Create('The Stream is not opened');
  if  (FBytesToRead >=0) and (FPosition >= FBytesToRead) then
  begin
    Buffer := nil;
    Bytes := 0;
    Exit;
  end;
  if BufStart >= BufEnd then
  begin
    BufStart := 0;
    Sleep(DS_POLLING_INTERVAL);
    DSW_QueryInputFilled(DSW, l);
    if l > _BufSize then
    begin
      l := _BufSize; (* We have lost some data.
                        Generally this shouldn't happen. *)
      Inc(FUnderruns);
    end;
//    l := l - (l mod 1024);
    DSW_ReadBlock(DSW, @Buf[0], l);
    BufEnd := l;
  end;
  if Bytes > (BufEnd - BufStart) then
    Bytes := BufEnd - BufStart;
  Buffer := @Buf[BufStart];
  Inc(BufStart, Bytes);
  Inc(FPosition, Bytes);
end;

procedure TDXAudioIn.SetRecTime;
begin
  FRecTime := aRecTime;
  if FRecTime > 0 then FBytesToRead := FRecTime*FFreq*FSampleSize
  else FBytesToRead := -1;
end;

procedure TDXAudioIn.SetDeviceNumber(i : Integer);
begin
  FDeviceNumber := i
end;

function TDXAudioIn.GetDeviceName(Number : Integer) : String;
begin
  if (Number < FDeviceCount) then Result := PChar(@(Devices.dinfo[Number].Name[0]))
  else Result := '';
end;

function TDXAudioIn.GetTotalTime : Integer;
var
  BytesPerSec : Integer;
begin
  BytesPerSec := FFreq*FSampleSize;
  Result := Round(FBytesToRead/BytesPerSec);
end;

procedure TDXAudioIn._Pause;
begin
  DSW_StopInput(DSW);
end;

procedure TDXAudioIn._Resume;
begin
  DSW_StartInput(DSW);
end;

end.