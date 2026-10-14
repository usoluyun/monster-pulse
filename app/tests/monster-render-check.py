"""Semantic checks against actual Dock rendering, independent of snapshots."""
import sys
from pathlib import Path
from PIL import Image, ImageChops, ImageCms
from io import BytesIO
root = Path(sys.argv[1])
def image(state):
    img = Image.open(root / f'monster-{state}.png').convert('RGB')
    if 'icc_profile' in img.info:
        img = ImageCms.profileToProfile(img, ImageCms.ImageCmsProfile(BytesIO(img.info['icc_profile'])), ImageCms.createProfile('sRGB'))
    return img
def near(pixel, target): return max(abs(a-b) for a,b in zip(pixel,target)) <= 3
white, used = (246,244,239), (117,136,151)
for percent in (100,70,50,15,0):
    img=image(str(percent)); w=u=0
    for y in range(img.height):
        pixels=[img.getpixel((x,y)) for x in range(img.width)]
        row_white=sum(near(p,white) for p in pixels)
        row_used=sum(near(p,used) for p in pixels)
        eyes=sum(near(p,(23,27,33)) for p in pixels)
        # Eyes are holes in the visible fill. Assign their area to the surrounding fill on that row.
        w+=row_white+(eyes if row_white>row_used else 0)
        u+=row_used+(eyes if row_used>row_white else 0)
    assert w+u>1500, f'{percent}: missing body'
    assert abs(w/(w+u)-percent/100)<0.025, f'{percent}: white area {w/(w+u)}'
for state,color in [('normal',(54,94,89)),('off',(89,70,56)),('unknown',(69,70,75))]:
    img=image(state)
    # Sample the ground between the two bottom rings; 94% now lies on the outer stroke.
    assert near(img.getpixel((img.width//2,int(img.height*.925))),color), f'{state}: proxy ground'
assert ImageChops.difference(image('motion-a'),image('motion-b')).getbbox(), 'motion frozen'
for state in ('hidden-cpu','hidden-gpu'):
    assert not ImageChops.difference(image(state),image('idle')).getbbox(), f'{state}: hidden load still changes pose'
zero,full,short,week=[image('time-'+state) for state in ('zero','full','short','week')]
assert not ImageChops.difference(zero,image('time-unknown')).getbbox(), 'unknown time invents progress'
assert ImageChops.difference(zero,full).getbbox(), 'time rings missing'
# Each ring is independent. Together their light contributions reproduce the full pair.
for y in range(full.height):
    for x in range(full.width):
        z,f,s,w=[img.getpixel((x,y)) for img in (zero,full,short,week)]
        assert max(abs(f[i]-(s[i]+w[i]-z[i])) for i in range(3))<=4, 'rings overlap or share progress'
# Inspect actual 43pt rendering as well as the larger fixture. All four corner arcs must survive.
for suffix in ('','-small'):
    z,f=image('time-zero'+suffix),image('time-full'+suffix)
    for inset,radius in ((6.5,21.5),(12,16)):
        for cx,cy,sign_x,sign_y in ((28,28,-1,-1),(100,28,1,-1),(100,100,1,1),(28,100,-1,1)):
            px=(cx+sign_x*radius/2**.5)*f.width/128
            py=(cy+sign_y*radius/2**.5)*f.height/128
            differences=[max(abs(a-b) for a,b in zip(f.getpixel((x,y)),z.getpixel((x,y))))
                         for x in range(max(0,int(px)-1),min(f.width,int(px)+2))
                         for y in range(max(0,int(py)-1),min(f.height,int(py)+2))]
            assert max(differences)>15, f'{suffix}: clipped corner ({cx},{cy}) ring {inset}'

# The piggy bank has no time window, so neither progress nor the empty tracks may appear.
# An empty track would read as "progress not started" when the truth is that the source has
# no such window at all.
#
# Compared against the piggy-leak fixture, which is handed two fully elapsed time windows.
# If the renderer ignored them, leak would differ from the normal piggy fixture. Asserting
# equality proves the suppression on the renderer's own terms, rather than comparing two
# differently-shaped bodies pixel by pixel (their fills differ, so that test is meaningless).
assert not ImageChops.difference(image('piggy-comfortable'),image('piggy-leak')).getbbox(), \
    'piggy bank renders time rings even when windows are supplied'

# The smile must survive at 43pt. A deeper smile arcs the eyes into a thinner crescent,
# so dark coverage shrinks as prosperity rises — the direction is inverted from intuition,
# but a monotonic gap of this size proves the eye shape really changes on the Dock icon.
# A smile that only reads in the 128pt fixture is an indistinguishable oval at 43pt.
def eye_coverage(state):
    img=image(state); s=img.width/256
    # Face region in the 256px design space, covering both eyes of the piggy form.
    return sum(1 for y in range(int(158*s),int(202*s)) for x in range(int(94*s),int(170*s))
               if sum(img.getpixel((x,y)))/3<120)
smile=[eye_coverage('piggy-'+state) for state in ('drained','tight','comfortable','abundant')]
assert smile==sorted(smile,reverse=True) and smile[0]-smile[-1]>60, f'smile not readable at 43pt: {smile}'

# Coins encode absolute amount, so the richest state must paint strictly more of them.
# Colour is sampled from the actual render rather than hard-coded: anti-aliasing at 43pt
# shifts the exact value, and a hard-coded hex would pass locally and fail elsewhere.
def coin_pixels(img):
    # Count gold-ish pixels rather than matching an exact hex: anti-aliasing at 43pt and
    # the 0.35pt coin stroke both shift the value, so a hard-coded colour matches nothing.
    # Gold reads as R>G>B with a wide gap between R and B, which no palette colour here has.
    return sum(1 for pixel in img.getdata()
               if pixel[0]-pixel[2]>60 and pixel[0]>130 and pixel[1]>pixel[2])
counts={state:coin_pixels(image(state)) for state in
        ('piggy-abundant','piggy-comfortable','piggy-tight','piggy-drained')}
assert counts['piggy-abundant']>counts['piggy-comfortable']>counts['piggy-tight']>counts['piggy-drained']>0, f'coins not monotonic: {counts}'
# No consumption data must not be drawn as zero coins: that would claim an empty wallet.
assert coin_pixels(image('piggy-unknown'))==0, 'unknown prosperity painted coins'
assert ImageChops.difference(image('piggy-abundant'),image('piggy-drained')).getbbox(), 'abundance is visually identical'
print('PASS: Monster area, proxy, motion, independent time rings, 43pt corner clearance and piggy bank coins')
