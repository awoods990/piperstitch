import { useEffect, useState } from "react";

/** True while the given CSS media query matches; re-renders when it changes
 *  (rotation, window resize, a phone's split view). */
export function useMediaQuery(query: string): boolean {
  const get = () => typeof window !== "undefined" && window.matchMedia(query).matches;
  const [matches, setMatches] = useState(get);
  useEffect(() => {
    const mq = window.matchMedia(query);
    const onChange = () => setMatches(mq.matches);
    onChange();
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, [query]);
  return matches;
}

/** Phone-sized viewport: the editor collapses to canvas + bottom sheet. Keep
 *  in sync with the `--phone` breakpoint in styles.css. */
export const PHONE_QUERY = "(max-width: 760px)";
/** A finger rather than a mouse: bigger targets, touch wording, no hover tips. */
export const COARSE_QUERY = "(pointer: coarse)";
