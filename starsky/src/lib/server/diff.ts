// Unified diff helper used by the SFTP studio (local vs remote comparison).

export function createUnifiedDiff(
  original: string,
  modified: string,
  filePath = "workspace/file"
): string {
  const oldLines = original ? original.replace(/\r\n/g, "\n").split("\n") : [];
  const newLines = modified ? modified.replace(/\r\n/g, "\n").split("\n") : [];
  const header = [
    `--- a/${filePath}`,
    `+++ b/${filePath}`,
    `@@ -1,${oldLines.length} +1,${newLines.length} @@`,
  ];

  const body: string[] = [];
  const maxLen = Math.max(oldLines.length, newLines.length);
  let start = 0;
  while (start < maxLen && oldLines[start] === newLines[start]) {
    start++;
  }
  let endOld = oldLines.length - 1;
  let endNew = newLines.length - 1;
  while (
    endOld >= start &&
    endNew >= start &&
    oldLines[endOld] === newLines[endNew]
  ) {
    endOld--;
    endNew--;
  }

  const ctxStart = Math.max(0, start - 3);
  for (let i = ctxStart; i < start; i++) {
    body.push(` ${oldLines[i]}`);
  }
  for (let i = start; i <= endOld; i++) {
    body.push(`-${oldLines[i]}`);
  }
  for (let i = start; i <= endNew; i++) {
    body.push(`+${newLines[i]}`);
  }
  const ctxEnd = Math.min(oldLines.length - 1, endOld + 3);
  for (let i = endOld + 1; i <= ctxEnd; i++) {
    body.push(` ${oldLines[i]}`);
  }

  if (body.length === 0) {
    return `--- a/${filePath}\n+++ b/${filePath}\n@@ No changes @@`;
  }
  return [...header, ...body].join("\n");
}
