// VESPER-1 approach scene: one fullscreen fragment shader.
// `progress` (0..1) flies the camera from cruise to touchdown.
struct Params {
  resolution: vec2f,
  offset: vec2f,
  time: f32,
  progress: f32,
  motion: f32,
}

@group(0) @binding(0) var<uniform> params: Params;

const PI: f32 = 3.14159265359;
const H_START: f32 = 2.6;
const H_END: f32 = 0.00035;
const SUN: vec3f = vec3f(0.729, 0.292, 0.619);

fn hash21(p: vec2f) -> f32 {
  var q = fract(p * vec2f(123.34, 456.21));
  q += vec2f(dot(q, q + vec2f(45.32)));
  return fract(q.x * q.y);
}

// Integer hash: stays crisp at the very high frequencies used near the ground.
fn hash31(p: vec3f) -> f32 {
  let q = vec3u(vec3i(p));
  var n = (q.x * 1597334677u) ^ (q.y * 3812015801u) ^ (q.z * 2798796415u);
  n = (n ^ (n >> 15u)) * 2246822519u;
  n = n ^ (n >> 13u);
  return f32(n & 0xffffffu) / 16777215.0;
}

fn noise3(p: vec3f) -> f32 {
  let i = floor(p);
  let f = fract(p);
  let u = f * f * (3.0 - 2.0 * f);
  let a = mix(hash31(i), hash31(i + vec3f(1.0, 0.0, 0.0)), u.x);
  let b = mix(hash31(i + vec3f(0.0, 1.0, 0.0)), hash31(i + vec3f(1.0, 1.0, 0.0)), u.x);
  let c = mix(hash31(i + vec3f(0.0, 0.0, 1.0)), hash31(i + vec3f(1.0, 0.0, 1.0)), u.x);
  let d = mix(hash31(i + vec3f(0.0, 1.0, 1.0)), hash31(i + vec3f(1.0, 1.0, 1.0)), u.x);
  return mix(mix(a, b, u.y), mix(c, d, u.y), u.z);
}

// Large-scale albedo regions (always the same, whatever the altitude).
fn regions(p: vec3f) -> f32 {
  var v = 0.0;
  var amp = 0.5;
  var q = p * 1.7 + vec3f(3.1, 7.7, 1.3);
  for (var i = 0; i < 5; i++) {
    v += amp * noise3(q);
    q = q * 2.03 + vec3f(11.0);
    amp *= 0.5;
  }
  return v;
}

// Scale-relative relief: octaves fade in as they grow past a few pixels, so
// the ground keeps gaining detail all the way down without aliasing.
// `p` is the point on the unit sphere; `loc` is the same point relative to the
// landing site, which keeps float precision for the finest octaves.
fn relief(p: vec3f, loc: vec3f, footprint: f32) -> f32 {
  var v = 0.0;
  var freq = 2.0;
  for (var k = 0; k < 22; k++) {
    let r = 1.0 / (freq * footprint); // pixels per wavelength
    if (r < 2.0) { break; }
    let w = smoothstep(2.0, 8.0, r) * min(1.0, pow(260.0 / r, 0.62));
    if (w > 0.02) {
      var q = p;
      if (k >= 10) { q = loc; }
      v += w * (noise3(q * freq + vec3f(f32(k) * 17.3)) - 0.5);
    }
    freq *= 2.0;
  }
  return v;
}

fn starField(direction: vec3f) -> vec3f {
  let d = normalize(direction);
  let spherical = vec2f(atan2(d.z, d.x) / (2.0 * PI), asin(clamp(d.y, -1.0, 1.0)) / PI);
  let grid = spherical * vec2f(720.0, 360.0);
  let cell = floor(grid);
  let local = fract(grid) - 0.5;
  let seed = hash21(cell);
  let radius = mix(0.03, 0.09, seed * seed);
  let point = smoothstep(radius, 0.0, length(local)) * step(0.984, seed);
  let temperature = hash21(cell + vec2f(17.0, 29.0));
  let tint = mix(vec3f(0.6, 0.72, 1.0), vec3f(1.0, 0.8, 0.6), temperature);
  return tint * point * (0.8 + seed * 2.0);
}

fn rotY(p: vec3f, a: f32) -> vec3f {
  let c = cos(a);
  let s = sin(a);
  return vec3f(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

@fragment fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
  let aspect = params.resolution.x / params.resolution.y;
  let p = clamp(params.progress, 0.0, 1.0);
  let time = params.time;
  // uv origin is top-left; flip so +y is up.
  var screen = (uv * 2.0 - 1.0) * vec2f(aspect, -1.0);

  // Camera path
  let ease = p * p * (3.0 - 2.0 * p);
  let h = exp(mix(log(H_START), log(H_END), ease));
  let pitch = smoothstep(0.7, 1.0, p) * 1.33;
  let cruise = 1.0 - smoothstep(0.0, 0.45, p);
  let entry = smoothstep(0.36, 0.5, p) * (1.0 - smoothstep(0.6, 0.72, p));

  screen -= params.offset * cruise;
  screen += entry * params.motion * 0.007 * vec2f(sin(time * 47.0), cos(time * 61.0));

  let ro = vec3f(0.0, 0.0, 1.0 + h);
  let fwd = vec3f(0.0, sin(pitch), -cos(pitch));
  let up = vec3f(0.0, cos(pitch), sin(pitch));
  let right = vec3f(1.0, 0.0, 0.0);
  let rd = normalize(fwd * 1.5 + right * screen.x + up * screen.y);

  let spin = (1.0 - smoothstep(0.0, 0.3, p)) * 0.9 + time * 0.012 * (1.0 - smoothstep(0.0, 0.3, p)) * params.motion;

  // Ray / unit sphere
  let bq = dot(ro, rd);
  let cq = dot(ro, ro) - 1.0;
  let disc = bq * bq - cq;
  let inAir = exp(-h / 0.01);

  var col = vec3f(0.0);
  if (disc > 0.0 && -bq - sqrt(disc) > 0.0) {
    let t = -bq - sqrt(disc);
    let pos = ro + rd * t;
    let n = normalize(pos);
    let sp = rotY(n, spin);
    let facing = max(dot(n, -rd), 0.12);
    let footprint = t * 1.4 / (params.resolution.y * 1.5) / facing;

    // Bump from relief
    let tx = normalize(cross(vec3f(0.0, 1.0, 0.0), n));
    let ty = cross(n, tx);
    let e = footprint * 2.0;
    let loc = vec3f(rd.xy * t, h + rd.z * t);
    let r0 = relief(sp, loc, footprint);
    let rx = relief(rotY(normalize(n + tx * e), spin), loc + tx * e, footprint);
    let ry = relief(rotY(normalize(n + ty * e), spin), loc + ty * e, footprint);
    let bumpN = normalize(n - (tx * (rx - r0) + ty * (ry - r0)) * 1.1);

    let reg = regions(sp);
    var albedo = mix(vec3f(0.24, 0.085, 0.05), vec3f(0.8, 0.33, 0.14), smoothstep(0.3, 0.68, reg));
    albedo = mix(albedo, vec3f(0.95, 0.52, 0.27), smoothstep(0.62, 0.8, reg) * 0.6);
    albedo *= 1.0 + r0 * 0.55;
    let cap = smoothstep(0.82, 0.9, abs(sp.y) + (reg - 0.5) * 0.12);
    albedo = mix(albedo, vec3f(0.93, 0.9, 0.88), cap);

    let ndl = dot(bumpN, SUN);
    let day = smoothstep(-0.12, 0.25, dot(n, SUN));
    let diffuse = max(ndl, 0.0) * day;
    col = albedo * (diffuse * 1.0 + 0.035 + 0.22 * inAir);

    // Limb haze seen from orbit
    let rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.5);
    col += vec3f(0.95, 0.55, 0.32) * rim * day * 0.55 * (1.0 - inAir);

    // Aerial haze once inside the atmosphere
    let fog = (1.0 - exp(-t / 0.02)) * inAir * 0.92;
    col = mix(col, vec3f(0.82, 0.5, 0.3), fog);
  } else {
    let tc = -bq;
    var b = h;
    if (tc > 0.0) { b = max(length(ro + rd * tc) - 1.0, 0.0); }
    let limb = exp(-b / 0.014) * mix(0.4, 1.0, inAir);
    let lit = smoothstep(-0.3, 0.3, dot(normalize(ro + rd * max(tc, 0.0)), SUN));
    let skyAmt = clamp(limb * mix(lit, 1.0, inAir), 0.0, 1.0);
    let horizon = exp(-max(dot(rd, vec3f(0.0, 0.0, 1.0)), 0.0) * 6.0);
    let sky = mix(vec3f(0.6, 0.36, 0.22), vec3f(0.94, 0.68, 0.45), horizon);
    col = starField(rotY(rd, time * 0.002 * params.motion)) * (1.0 - skyAmt) + sky * skyAmt;
  }

  // Entry plasma
  let rr = length(screen / vec2f(aspect, 1.0));
  let ang = atan2(screen.y, screen.x);
  let streak = noise3(vec3f(ang * 7.0, rr * 4.0 - time * 5.0 * params.motion, 3.0));
  let plasma = entry * smoothstep(0.12, 1.05, rr) * (0.5 + 0.9 * streak);
  col += vec3f(1.0, 0.4, 0.1) * plasma * 2.4 + vec3f(1.0, 0.8, 0.55) * plasma * plasma * 0.8;
  col = mix(col, col * vec3f(1.12, 0.9, 0.75), entry * 0.6);

  // Touchdown dust
  let dustP = smoothstep(0.92, 0.975, p) * (1.0 - 0.65 * smoothstep(0.985, 1.0, p));
  let billow = noise3(vec3f(screen.x * 2.2, screen.y * 2.2 - time * 0.35 * params.motion, time * 0.12));
  let dust = dustP * smoothstep(0.75, -0.9, screen.y + (billow - 0.5) * 0.9);
  col = mix(col, vec3f(0.74, 0.52, 0.36) * (0.75 + 0.4 * billow), clamp(dust * 0.9, 0.0, 1.0));

  // Grade
  let vig = 1.0 - 0.32 * dot(uv - 0.5, uv - 0.5) * 2.0;
  col *= vig;
  col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
  col = mix(vec3f(dot(col, vec3f(0.2126, 0.7152, 0.0722))), col, 1.3);
  col = pow(clamp(col, vec3f(0.0), vec3f(1.0)), vec3f(1.0 / 2.2));
  col += (hash21(uv * params.resolution + vec2f(time)) - 0.5) / 255.0;
  return vec4f(col, 1.0);
}
