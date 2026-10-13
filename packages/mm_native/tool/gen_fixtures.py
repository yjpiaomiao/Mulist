"""Generates the small audio fixtures under test/fixtures.

Requires ffmpeg on PATH and the `mutagen` Python package (an independent
tag implementation, so the fixtures are not produced by the code under
test). The output is committed; re-run only when adding fixtures:

    python tool/gen_fixtures.py
"""
import base64
import os
import random
import shutil
import struct
import subprocess
import tempfile

from mutagen import (aiff, apev2, asf, dsdiff, dsf, flac, id3, mp4, oggopus, oggspeex,
                     oggvorbis, trueaudio, wave)
from mutagen.flac import Picture

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'test', 'fixtures')
os.makedirs(OUT, exist_ok=True)
TMP = tempfile.mkdtemp()
rnd = random.Random(42)


def ff(*args):
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', *args], check=True)


def sine(out, *codec, rate=22050, dur=0.6, ch=1):
    ff('-f', 'lavfi', '-i', f'sine=frequency=440:sample_rate={rate}:duration={dur}',
       '-ac', str(ch), *codec, out)


def p(name):
    return os.path.join(OUT, name)


def read(path):
    with open(path, 'rb') as f:
        return f.read()


def write(path, data, mode='wb'):
    with open(path, mode) as f:
        f.write(data)


# ---------------------------------------------------------------- images
JPG = os.path.join(TMP, 'front.jpg')
PNG = os.path.join(TMP, 'back.png')
ff('-f', 'lavfi', '-i', 'testsrc=size=96x96:rate=1', '-frames:v', '1', JPG)
ff('-f', 'lavfi', '-i', 'color=c=blue:size=40x40', '-frames:v', '1', PNG)
FRONT, BACK = read(JPG), read(PNG)
shutil.copy(JPG, p('cover.jpg'))
shutil.copy(PNG, p('cover.png'))


def apic(kind, data, mime, desc=''):
    return id3.APIC(encoding=3, mime=mime, type=kind, desc=desc, data=data)


def rich_id3(t, v24=False):
    enc = 3 if v24 else 1
    t.add(id3.TIT2(encoding=enc, text=['晴天']))
    t.add(id3.TPE1(encoding=enc, text=['周杰伦', 'Jay Chou'] if v24 else ['周杰伦']))
    t.add(id3.TALB(encoding=enc, text=['叶惠美']))
    t.add(id3.TPE2(encoding=enc, text=['周杰伦']))
    t.add(id3.TRCK(encoding=enc, text=['3/11']))
    t.add(id3.TPOS(encoding=enc, text=['1/1']))
    t.add(id3.TCON(encoding=enc, text=['流行']))
    t.add(id3.TCOM(encoding=enc, text=['周杰伦']))
    t.add(id3.COMM(encoding=enc, lang='chi', desc='', text=['备注：测试']))
    t.add(id3.TXXX(encoding=enc, desc='REPLAYGAIN_TRACK_GAIN', text=['-6.50 dB']))
    t.add(id3.TXXX(encoding=enc, desc='自定义字段', text=['值一']))
    t.add(id3.USLT(encoding=enc, lang='chi', desc='', text='故事的小黄花'))
    t.add(apic(3, FRONT, 'image/jpeg', 'front'))
    t.add(apic(4, BACK, 'image/png', 'back'))
    if v24:
        t.add(id3.TDRC(encoding=enc, text=['2003-07-31']))
    else:
        t.add(id3.TYER(encoding=enc, text=['2003']))


# ---------------------------------------------------------------- MP3
base_mp3 = os.path.join(TMP, 'base.mp3')
sine(base_mp3, '-c:a', 'libmp3lame', '-b:a', '64k', '-write_xing', '0', '-id3v2_version', '0',
     '-write_id3v1', '0')

shutil.copy(base_mp3, p('notag.mp3'))

shutil.copy(base_mp3, p('id3v23_rich.mp3'))
t = id3.ID3()
rich_id3(t)
t.save(p('id3v23_rich.mp3'), v2_version=3, padding=lambda info: 2048)

shutil.copy(base_mp3, p('id3v24_multi.mp3'))
t = id3.ID3()
rich_id3(t, v24=True)
t.save(p('id3v24_multi.mp3'), v2_version=4, padding=lambda info: 1024)

shutil.copy(base_mp3, p('id3v23_nopad.mp3'))
t = id3.ID3()
t.add(id3.TIT2(encoding=1, text=['无填充']))
t.add(id3.TPE1(encoding=1, text=['歌手']))
t.save(p('id3v23_nopad.mp3'), v2_version=3, padding=lambda info: 0)

# ID3v2 + APEv2 + ID3v1 together.
shutil.copy(base_mp3, p('three_tags.mp3'))
ape = apev2.APEv2()
ape['Title'] = 'APE Title'
ape['Artist'] = 'APE Artist'
ape['Custom'] = 'keep me'
ape.save(p('three_tags.mp3'))
t = id3.ID3()
t.add(id3.TIT2(encoding=1, text=['三种标签']))
t.add(id3.TPE1(encoding=1, text=['艺术家']))
t.add(id3.TALB(encoding=1, text=['Album']))
t.save(p('three_tags.mp3'), v2_version=3, v1=2, padding=lambda info: 512)

shutil.copy(base_mp3, p('v1_only.mp3'))
t = id3.ID3()
t.add(id3.TIT2(encoding=0, text=['V1 Title']))
t.add(id3.TPE1(encoding=0, text=['V1 Artist']))
t.save(p('v1_only.mp3'), v1=2)
data = read(p('v1_only.mp3'))
if data[:3] == b'ID3':  # strip the v2 part, keep the v1 trailer
    size = (((data[6] & 0x7f) << 21) | ((data[7] & 0x7f) << 14) | ((data[8] & 0x7f) << 7)
            | (data[9] & 0x7f))
    data = data[10 + size:]
write(p('v1_only.mp3'), data)


# ---------------------------------------------------------------- FLAC
def rich_vorbis(c):
    c['TITLE'] = ['晴天']
    c['ARTIST'] = ['周杰伦', 'Jay Chou']
    c['ALBUM'] = ['叶惠美']
    c['ALBUMARTIST'] = ['周杰伦']
    c['TRACKNUMBER'] = ['3']
    c['TRACKTOTAL'] = ['11']
    c['DISCNUMBER'] = ['1']
    c['DATE'] = ['2003']
    c['GENRE'] = ['流行', 'Pop']
    c['COMPOSER'] = ['周杰伦']
    c['COMMENT'] = ['备注']
    c['REPLAYGAIN_TRACK_GAIN'] = ['-6.50 dB']
    c['CUSTOMFIELD'] = ['值']


def flac_pic(kind, data, mime, w, h):
    pic = Picture()
    pic.type = kind
    pic.mime = mime
    pic.desc = ''
    pic.width, pic.height, pic.depth = w, h, 24
    pic.data = data
    return pic


base_flac = os.path.join(TMP, 'base.flac')
sine(base_flac, '-c:a', 'flac')
shutil.copy(base_flac, p('rich.flac'))
f = flac.FLAC(p('rich.flac'))
rich_vorbis(f)
f.add_picture(flac_pic(3, FRONT, 'image/jpeg', 96, 96))
f.add_picture(flac_pic(4, BACK, 'image/png', 40, 40))
f.save(padding=lambda info: 4096)

shutil.copy(base_flac, p('nopad.flac'))
f = flac.FLAC(p('nopad.flac'))
f['TITLE'] = ['No padding']
f.save(padding=lambda info: 0)

# ---------------------------------------------------------------- MP4
for name, codec in (('aac.m4a', ['-c:a', 'aac', '-b:a', '48k']), ('alac.m4a', ['-c:a', 'alac'])):
    sine(p(name), *codec)
    m = mp4.MP4(p(name))
    m['\xa9nam'] = ['晴天']
    m['\xa9ART'] = ['周杰伦']
    m['\xa9alb'] = ['叶惠美']
    m['aART'] = ['周杰伦']
    m['trkn'] = [(3, 11)]
    m['disk'] = [(1, 1)]
    m['\xa9day'] = ['2003']
    m['\xa9gen'] = ['流行']
    m['\xa9wrt'] = ['周杰伦']
    m['\xa9cmt'] = ['备注']
    m['----:com.apple.iTunes:MOOD'] = [b'Happy']
    m['covr'] = [mp4.MP4Cover(FRONT, imageformat=mp4.MP4Cover.FORMAT_JPEG)]
    m.save()

# ---------------------------------------------------------------- Ogg
sine(p('vorbis.ogg'), '-c:a', 'libvorbis', '-q:a', '0')
o = oggvorbis.OggVorbis(p('vorbis.ogg'))
rich_vorbis(o)
o['METADATA_BLOCK_PICTURE'] = [
    base64.b64encode(flac_pic(3, FRONT, 'image/jpeg', 96, 96).write()).decode()]
o.save()

sine(p('opus.opus'), '-c:a', 'libopus', '-b:a', '24k', rate=48000)
o = oggopus.OggOpus(p('opus.opus'))
rich_vorbis(o)
o.save()

sine(p('speex.spx'), '-c:a', 'libspeex', rate=16000)
o = oggspeex.OggSpeex(p('speex.spx'))
o['TITLE'] = ['斯皮克斯']
o['ARTIST'] = ['A', 'B']
o.save()

# ---------------------------------------------------------------- RIFF / AIFF
sine(p('info.wav'), '-c:a', 'pcm_s16le', '-metadata', 'title=Info Title', '-metadata',
     'artist=Info Artist', dur=0.2)
sine(p('id3.wav'), '-c:a', 'pcm_s16le', dur=0.2)
w = wave.WAVE(p('id3.wav'))
w.add_tags()
rich_id3(w.tags)
w.save(v2_version=3)

sine(p('id3.aiff'), '-c:a', 'pcm_s16be', dur=0.2)
a = aiff.AIFF(p('id3.aiff'))
a.add_tags()
rich_id3(a.tags)
a.save(v2_version=4)

# ---------------------------------------------------------------- APE-tagged lossless
sine(p('ape_tag.wv'), '-c:a', 'wavpack')
t = apev2.APEv2()
t['Title'] = '沃夫帕克'
t['Artist'] = ['甲', '乙']  # APE multi-value (NUL separated)
t['Album'] = 'WavPack'
t['Year'] = '2020'
t['Cover Art (Front)'] = apev2.APEValue(b'cover.jpg\x00' + FRONT, apev2.BINARY)
t.save(p('ape_tag.wv'))

sine(p('id3.tta'), '-c:a', 'tta')
tt = trueaudio.TrueAudio(p('id3.tta'))
tt.add_tags()
tt.tags.add(id3.TIT2(encoding=1, text=['真音频']))
tt.tags.add(id3.TPE1(encoding=1, text=['艺术家']))
tt.save()

sine(p('asf.wma'), '-c:a', 'wmav2', '-b:a', '32k')
w = asf.ASF(p('asf.wma'))
w['Title'] = ['视窗媒体']
w['Author'] = ['甲']
w['WM/AlbumTitle'] = ['专辑']
w['WM/AlbumArtist'] = ['专辑艺术家']
w['WM/TrackNumber'] = [asf.ASFDWordAttribute(3)]
w['WM/Genre'] = ['流行', 'Pop']
w.save()


def ape_file(path, frames=3, blocks=73728, rate=44100, ch=2, bits=16):
    seek = struct.pack('<%dI' % frames, *[52 + 24 + 4 * frames + i * 1000 for i in range(frames)])
    payload = bytes(rnd.getrandbits(8) for _ in range(1000 * frames))
    desc = b'MAC ' + struct.pack('<HHIIIIIII', 3990, 0, 52, 24, len(seek), 0, len(payload), 0,
                                 0) + bytes(16)
    head = struct.pack('<HHIIIHHI', 2000, 0, blocks, blocks // 2, frames, bits, ch, rate)
    write(path, desc + head + seek + payload)


ape_file(p('monkey.ape'))
t = apev2.APEv2()
t['Title'] = '猴子音频'
t['Artist'] = 'Monkey'
t.save(p('monkey.ape'))
write(p('monkey.ape'), b'TAG' + b'V1 Title'.ljust(30, b'\0') + b'V1 Artist'.ljust(30, b'\0')
      + bytes(30 + 4 + 30) + b'\xff', 'ab')


def mpc_sv7(path, frames=40):
    head = b'MP+' + bytes([0x17]) + struct.pack('<II', frames, 0) + bytes(48)
    payload = bytes(rnd.getrandbits(8) for _ in range(3000))
    write(path, head + payload)


mpc_sv7(p('musepack.mpc'))
t = apev2.APEv2()
t['Title'] = 'Musepack 标题'
t['Artist'] = 'MPC'
t.save(p('musepack.mpc'))


# ---------------------------------------------------------------- DSD
def dsf_file(path, blocks=2, ch=2):
    block = 4096
    data = bytes(rnd.getrandbits(8) for _ in range(block * ch * blocks))
    samples = block * 8 * blocks
    fmt = b'fmt ' + struct.pack('<QIIIIIIQII', 52, 1, 0, 2, ch, 2822400, 1, samples, block, 0)
    dat = b'data' + struct.pack('<Q', 12 + len(data)) + data
    total = 28 + len(fmt) + len(dat)
    hdr = b'DSD ' + struct.pack('<QQQ', 28, total, 0)
    write(path, hdr + fmt + dat)


dsf_file(p('notag.dsf'))
dsf_file(p('id3.dsf'))
d = dsf.DSF(p('id3.dsf'))
d.add_tags()
rich_id3(d.tags)
d.save(v2_version=3)


def chunk(cid, body):
    out = cid + struct.pack('>Q', len(body)) + body
    if len(body) & 1:
        out += b'\0'
    return out


def dff_file(path, diin=False):
    fs = chunk(b'FS  ', struct.pack('>I', 2822400))
    chnl = chunk(b'CHNL', struct.pack('>H', 2) + b'SLFTSRGT')
    name = b'not compressed'
    cmpr = chunk(b'CMPR', b'DSD ' + bytes([len(name)]) + name +
                 (b'\0' if (len(name) + 1) & 1 else b''))
    prop = chunk(b'PROP', b'SND ' + fs + chnl + cmpr)
    fver = chunk(b'FVER', struct.pack('>I', 0x01050000))
    dsd = chunk(b'DSD ', bytes(rnd.getrandbits(8) for _ in range(8192)))
    extra = b''
    if diin:
        def txt(s):
            b = s.encode('utf-8')
            return struct.pack('>I', len(b)) + b
        extra = chunk(b'DIIN', chunk(b'DITI', txt('DIIN Title')) + chunk(b'DIAR', txt('DIIN Artist')))
    body = b'DSD ' + fver + prop + dsd + extra
    write(path, b'FRM8' + struct.pack('>Q', len(body)) + body)


dff_file(p('id3.dff'))
d = dsdiff.DSDIFF(p('id3.dff'))
d.add_tags()
rich_id3(d.tags)
d.save(v2_version=4)
dff_file(p('diin.dff'), diin=True)

shutil.rmtree(TMP)
total = sum(os.path.getsize(p(n)) for n in os.listdir(OUT))
print('fixtures:', len(os.listdir(OUT)), 'files,', total, 'bytes')
