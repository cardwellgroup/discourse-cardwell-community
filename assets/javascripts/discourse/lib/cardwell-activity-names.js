// Part 1 (306-535): "code:handle" → name, from the activity stream rows the
// server named. PostActionDescription, which draws the row's line, is only
// handed the handle, so the names are collected as the rows are built.
export const activityNames = new Map();

export function activityKey(code, handle) {
  return `${code}:${handle}`;
}
