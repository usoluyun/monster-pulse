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
print('PASS: Monster area, proxy, motion, independent time rings and 43pt corner clearance')
