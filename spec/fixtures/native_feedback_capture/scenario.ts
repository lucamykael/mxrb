// Runs unchanged in the Mendix client and in the exported Ruby application's browser.
(async () => {
  // Exercise the original widget's DOM capture fallback in headless browsers.
  // The interactive OS screen picker is outside this reproducible scenario.
  if (navigator.mediaDevices)
    Object.defineProperty(navigator.mediaDevices, "getDisplayMedia", {
      value: undefined,
    });
  const waitFor = async (check: () => boolean, label: string) => {
    for (let attempt = 0; attempt < 200; attempt++) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error(`Feedback timeout: ${label}`);
  };
  const assert = (condition: unknown, label: string) => {
    if (!condition) throw new Error(`Feedback assertion failed: ${label}`);
  };
  const click = (selector: string) => {
    const element = document.querySelector<HTMLButtonElement>(selector);
    assert(element, selector);
    element!.click();
  };
  const finish = async (name: string) => {
    await waitFor(
      () => document.body.innerText.includes(`Finished ${name}`),
      `finish ${name}`,
    );
    click(
      'button[aria-label="Dismiss notification"], .modal-dialog button.btn-primary',
    );
    await waitFor(
      () => !document.body.innerText.includes(`Finished ${name}`),
      "dismiss",
    );
  };
  const canvases = () => [
    ...document.querySelectorAll<HTMLCanvasElement>("canvas"),
  ];
  const ready = async () => {
    await waitFor(
      () =>
        canvases().length === 2 &&
        canvases()[0].width > 0 &&
        canvases()[1].onmousedown !== null &&
        canvases()[0].getContext("2d")!.getImageData(0, 0, 1, 1).data[3] > 0,
      "image and drawing ready",
    );
  };
  const draw = () => {
    const canvas = canvases()[1];
    const rect = canvas.getBoundingClientRect();
    for (const [type, offset] of [
      ["mousedown", 15],
      ["mousemove", 35],
      ["mousemove", 55],
      ["mouseup", 55],
    ] as const) {
      canvas.dispatchEvent(
        new MouseEvent(type, {
          bubbles: true,
          buttons: type === "mouseup" ? 0 : 1,
          clientX: rect.left + offset,
          clientY: rect.top + offset,
        }),
      );
    }
  };
  const pixels = (canvas: HTMLCanvasElement) =>
    canvas.getContext("2d")!.getImageData(0, 0, canvas.width, canvas.height)
      .data;
  const drawn = () =>
    pixels(canvases()[1]).some((value, index) => index % 4 === 3 && value > 0);
  const storedImage = async (name: string) => {
    const value = JSON.parse(
      localStorage.getItem(`mxrb-capture-${name}`)!,
    ).ImageB64;
    assert(
      typeof value === "string" && value.startsWith("data:image/png;base64,"),
      `${name} PNG`,
    );
    const image = new Image();
    image.src = value;
    await image.decode();
    const canvas = document.createElement("canvas");
    canvas.width = image.width;
    canvas.height = image.height;
    canvas.getContext("2d")!.drawImage(image, 0, 0);
    return canvas;
  };
  localStorage.removeItem("mxrb-capture-annotate");
  localStorage.removeItem("mxrb-capture-screenshot");
  click(".mx-name-Annotate");
  await ready();
  assert(
    canvases()[0].width === 160 && canvases()[0].height === 100,
    "source image dimensions",
  );
  const background = Array.from(pixels(canvases()[0]).slice(0, 4));
  assert(background.join(",") === "53,106,195,255", "source image color");
  assert(!drawn(), "initial blank annotation");
  draw();
  assert(drawn(), "drawing changes pixels");
  const clear = [
    ...document.querySelectorAll<HTMLButtonElement>("button"),
  ].find((button) => button.textContent?.trim() === "Clear");
  assert(clear, "Clear button");
  clear!.click();
  assert(!drawn(), "Clear removes annotation");
  draw();
  assert(drawn(), "drawing after Clear");
  const combined = document.createElement("canvas");
  combined.width = 160;
  combined.height = 100;
  combined.getContext("2d")!.drawImage(canvases()[0], 0, 0);
  combined.getContext("2d")!.drawImage(canvases()[1], 0, 0);
  const expected = pixels(combined);
  click('[data-testid="save-screenshot"]');
  await finish("Annotate");
  const annotated = await storedImage("annotate");
  assert(
    annotated.width === 160 && annotated.height === 100,
    "saved dimensions",
  );
  assert(
    pixels(annotated).every((value, index) => value === expected[index]),
    "saved composite pixels",
  );
  click(".mx-name-Annotate");
  await ready();
  click('[data-testid="cancel-screenshot"]');
  await finish("Annotate");
  const cancelledAnnotation = localStorage.getItem("mxrb-capture-annotate");
  click(".mx-name-Screenshot");
  await waitFor(
    () => !!document.querySelector('[data-testid="take-screenshot"]'),
    "capture toolbar",
  );
  click('[data-testid="take-screenshot"] + button');
  await finish("Screenshot");
  assert(
    JSON.parse(localStorage.getItem("mxrb-capture-screenshot")!).ImageB64 ===
      "uploadCancelled",
    "screenshot cancellation",
  );
  click(".mx-name-Screenshot");
  await waitFor(
    () => !!document.querySelector('[data-testid="take-screenshot"]'),
    "capture toolbar repeat",
  );
  click('[data-testid="take-screenshot"]');
  await ready();
  const screenshotDimensions = [canvases()[0].width, canvases()[0].height];
  assert(
    screenshotDimensions[0] > 100 && screenshotDimensions[1] > 100,
    "captured page dimensions",
  );
  assert(
    new Set(pixels(canvases()[0])).size > 16,
    "captured page contains content",
  );
  click('[data-testid="save-screenshot"]');
  await finish("Screenshot");
  const captured = await storedImage("screenshot");
  assert(
    captured.width === screenshotDimensions[0] &&
      captured.height === screenshotDimensions[1],
    "saved screenshot dimensions",
  );
  return {
    status: "passed",
    source_dimensions: [160, 100],
    background,
    drawing: true,
    clear: true,
    saved_pixels_match: true,
    cancelled_annotation: cancelledAnnotation,
    screenshot_cancellation: "uploadCancelled",
    screenshot_dimensions: screenshotDimensions,
    screenshot_png: true,
  };
})();
