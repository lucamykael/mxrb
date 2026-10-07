(async () => {
  const waitFor = async (check: () => boolean) => {
    for (let i = 0; i < 160; i += 1) {
      if (check()) return;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("Live page argument scenario timed out");
  };
  const click = (name: string) => {
    const button = document.querySelector<HTMLButtonElement>(
      `.mx-name-${name}`,
    );
    if (!button) throw new Error(`Missing button ${name}`);
    button.click();
  };
  click("Open");
  await waitFor(
    () => document.querySelector(".live-name")?.textContent === "Initial",
  );
  await waitFor(() => document.querySelector(".live-off") !== null);
  click("Toggle");
  await waitFor(
    () =>
      document.querySelector(".live-on") !== null &&
      document.querySelector(".live-enabled") !== null,
  );
  click("Toggle");
  await waitFor(
    () =>
      document.querySelector(".live-off") !== null &&
      document.querySelector(".live-enabled") === null,
  );
  click("Rename");
  await waitFor(
    () => document.querySelector(".live-name")?.textContent === "Updated",
  );
  click("Toggle");
  await waitFor(() => document.querySelector(".live-on") !== null);
  if (document.querySelector(".live-name")?.textContent !== "Updated")
    throw new Error("Named argument became stale");
  return { status: "passed", toggles: [true, false, true], name: "Updated" };
})();
