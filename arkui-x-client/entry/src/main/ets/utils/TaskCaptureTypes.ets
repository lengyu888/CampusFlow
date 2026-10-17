// An input suggestion only. It cannot execute a task or grant in-class permission.
export interface TaskCaptureIntent {
  requestRevision?: number;
  text: string;
  date: string;
  time: string;
  durationMinutes: number | null;
  anchorDate: string;
  timezone: string;
  source: string;
}
