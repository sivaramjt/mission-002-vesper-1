// WebGPU scene, following vgpu's documented fullscreen-effect pattern:
// init() -> surface() -> effect() -> frameLoop(), uniforms written with effect.set().
import { clock, effect, frameLoop, init, surface } from "vgpu";
import marsShader from "./mars.wgsl";

export interface SceneFrame {
  progress: number;
  motion: number;
}

export interface SceneOptions {
  /** Called once per frame with the seconds since the last one. */
  frame: (dt: number) => SceneFrame;
}

export interface Scene {
  dispose(): void;
}

// Where the planet sits during cruise, in screen units (y is -1..1, x is scaled by aspect).
const cruiseOffset = (width: number, height: number): [number, number] => {
  const aspect = width / height;
  return aspect > 1.1 ? [aspect * 0.42, 0.06] : [0, 0.52];
};

export async function createScene(canvas: HTMLCanvasElement, options: SceneOptions): Promise<Scene> {
  const gpu = await init();
  let disposed = false;

  try {
    const canvasSurface = surface(gpu, canvas, { dpr: [1, 1.5] });
    const [w, h] = canvasSurface.size;
    const mars = effect(gpu, marsShader, {
      set: {
        params: { resolution: [w, h], offset: cruiseOffset(w, h), time: 0, progress: 0, motion: 1 },
      },
    });
    await mars.compile(canvasSurface);

    canvasSurface.onResize(() => {
      const [width, height] = canvasSurface.size;
      mars.set({ params: { resolution: [width, height], offset: cruiseOffset(width, height) } });
    });

    const gpuClock = clock(gpu);
    frameLoop(gpu, (frame) => {
      if (disposed) return;
      const { progress, motion } = options.frame(Math.min(0.1, gpuClock.deltaTime));
      mars.set({ params: { time: gpuClock.time, progress, motion } });
      frame.pass(canvasSurface, mars);
    });
  } catch (error) {
    gpu.dispose();
    throw error;
  }

  return {
    dispose() {
      if (disposed) return;
      disposed = true;
      gpu.dispose();
    },
  };
}
