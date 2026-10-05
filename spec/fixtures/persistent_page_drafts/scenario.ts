declare const mx: { data: { get(options: Record<string, unknown>): void } };

(async () => {
  const rows = () =>
    new Promise<unknown[]>((resolve, reject) => {
      mx.data.get({ xpath: "//Drafts.Item", callback: resolve, error: reject });
    });
  const waitFor = async (predicate: () => boolean, label: string) => {
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
      if (predicate()) return;
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    throw new Error("Timed out: " + label);
  };
  const input = () =>
    document.querySelector<HTMLInputElement>(".mx-name-Name input");
  const click = (caption: string) => {
    const button = [...document.querySelectorAll("button")].find(
      (value) => value.textContent?.trim() === caption,
    );
    if (!button) throw new Error("Button missing: " + caption);
    button.click();
  };
  await waitFor(() => input()?.value === "Unsaved item", "initial draft");
  const before = (await rows()).length;
  if (before !== 0) throw new Error("Draft was committed during load");
  click("Change draft");
  await waitFor(
    () => input()?.value === "Changed before Save",
    "updated draft",
  );
  const afterChange = (await rows()).length;
  if (afterChange !== 0) throw new Error("Draft was committed during change");
  click("Save draft");
  let afterSave = 0;
  for (let attempt = 0; attempt < 100 && !afterSave; attempt++) {
    afterSave = (await rows()).length;
    if (!afterSave) await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (afterSave !== 1)
    throw new Error("Save did not persist exactly one object");
  return {
    status: "passed",
    before,
    afterChange,
    afterSave,
    value: input()?.value,
  };
})();
