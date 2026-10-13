import numpy as np, wave
SR=44100
def t(d): return np.arange(int(SR*d))/SR
def env(d,a=0.005,decay=3.0):
    x=t(d); e=np.exp(-x*decay); n=int(SR*a); e[:n]*=np.linspace(0,1,n); return e
def note(f): return 440*2**((f-69)/12)
def mix(parts,dur):
    out=np.zeros(int(SR*dur))
    for start,sig in parts:
        i=int(start*SR); out[i:i+len(sig)]+=sig[:len(out)-i]
    return out
def save(name,x):
    x=x/np.max(np.abs(x))*0.89
    fade=int(0.03*SR); x[-fade:]*=np.linspace(1,0,fade)
    y=(x*32767).astype('<i2'); s=np.stack([y,y],1)
    w=wave.open(name,'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR); w.writeframes(s.tobytes()); w.close()

# 1 八音盒 music box: plucked bell-ish high notes
def mbox(m,d=1.4):
    f=note(m); x=t(d)
    return (np.sin(2*np.pi*f*x)+0.35*np.sin(2*np.pi*f*3.0*x)*np.exp(-x*6)+0.15*np.sin(2*np.pi*f*5.4*x)*np.exp(-x*12))*env(d,0.002,3.2)
seq=[84,88,91,96,91,96]; times=[0,0.16,0.32,0.48,0.72,0.88]
save('musicbox.wav',mix([(tt,mbox(m)) for tt,m in zip(times,seq)],2.4))

# 2 马林巴上行 marimba
def marimba(m,d=1.0):
    f=note(m); x=t(d)
    return (np.sin(2*np.pi*f*x)+0.5*np.sin(2*np.pi*f*4*x)*np.exp(-x*18)+0.2*np.sin(2*np.pi*f*10*x)*np.exp(-x*40))*env(d,0.002,5)
seq=[72,76,79,84,88]; save('marimba.wav',mix([(i*0.11,marimba(m)) for i,m in enumerate(seq)]+[(0.6,marimba(84,1.3)*0.8),(0.6,marimba(91,1.3)*0.7)],2.0))

# 3 小号 fanfare
def brass(m,d,vib=True):
    f=note(m); x=t(d); ph=2*np.pi*f*x+(0.004*np.sin(2*np.pi*5.5*x)*2*np.pi*f/5.5 if vib else 0)
    s=sum((1/k)*np.sin(k*ph)*np.exp(-x*0.5*k/4) for k in range(1,9))
    e=np.minimum(1,x/0.03)*np.exp(-x*1.2); e[-int(0.08*SR):]*=np.linspace(1,0,int(0.08*SR))
    return s*e
save('fanfare.wav',mix([(0,brass(67,0.14,False)),(0.16,brass(67,0.14,False)),(0.32,brass(67,0.14,False)),(0.5,brass(72,1.2)),(0.5,brass(76,1.2)*0.6),(0.5,brass(79,1.2)*0.5)],1.9))

# 4 水滴 water drops
def drop(f0,d=0.35):
    x=t(d); f=f0*(1+2.5*np.exp(-x*40)); ph=2*np.pi*np.cumsum(f)/SR
    return np.sin(ph)*env(d,0.001,14)
save('droplets.wav',mix([(0,drop(900)),(0.18,drop(1200)),(0.36,drop(1500)),(0.62,drop(1100)),(0.78,drop(1800))],1.4))

# 5 颂钵 singing bowl (good for rest end / calm)
def bowl(f0,d=3.5):
    x=t(d); s=np.zeros_like(x)
    for r,a,dec in [(1,1,0.9),(2.71,0.5,1.4),(5.15,0.25,2.2),(8.4,0.12,3)]:
        s+=a*np.sin(2*np.pi*f0*r*x+0.3*np.sin(2*np.pi*0.8*x))*np.exp(-x*dec)
    s*=(1+0.15*np.sin(2*np.pi*3.2*x)); return s*env(d,0.004,0)
save('bowl.wav',mix([(0,bowl(320)),(1.0,bowl(427)*0.7)],4.2))

# 6 竹风铃 bamboo chimes
rng=np.random.default_rng(7)
def bamboo(f,d=0.6):
    x=t(d); return (np.sin(2*np.pi*f*x)+0.4*np.sin(2*np.pi*f*2.76*x)*np.exp(-x*20))*env(d,0.001,9)
pent=[note(m) for m in [74,76,79,81,83,86,88]]
parts=[(i*0.09+rng.uniform(0,0.04),bamboo(rng.choice(pent))*rng.uniform(0.6,1)) for i in range(12)]
save('bamboo.wav',mix(parts,1.9))
