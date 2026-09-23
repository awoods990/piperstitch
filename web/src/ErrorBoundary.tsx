// A crash in React unmounts the tree and leaves a white page: no message,
// no report, and a customer who assumes the product is broken because it
// looks broken. This catches it, says something honest, offers the two
// things that usually work, and tells us -- which is how we hear about it
// at all, since nobody emails about a blank screen.
import React from "react";

type Props = { children: React.ReactNode };
type State = { crashed: boolean };

async function report(error: Error, info: React.ErrorInfo) {
  try {
    await fetch("/api/v1/auth/client-error", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: error.name,
        message: error.message,
        page: location.pathname + location.search,
        stack: `${error.stack ?? ""}\n\nComponents:${info.componentStack ?? ""}`,
      }),
      keepalive: true,
    });
  } catch { /* offline, or we're the thing that's broken */ }
}

export default class ErrorBoundary extends React.Component<Props, State> {
  state: State = { crashed: false };

  static getDerivedStateFromError(): State { return { crashed: true }; }

  componentDidCatch(error: Error, info: React.ErrorInfo) { void report(error, info); }

  render() {
    if (!this.state.crashed) return this.props.children;
    return (
      <div className="crash">
        <h1>PiperStitch has stopped.</h1>
        <p>Something went wrong in the app &mdash; not with your design. We&rsquo;ve been told, with enough detail to find it.</p>
        <p className="crash-hint">Your saved projects are on our side and unaffected. Reloading fixes most of these.</p>
        <div className="crash-actions">
          <button className="btn primary" onClick={() => location.reload()}>Reload PiperStitch</button>
          <a className="btn ghost" href="mailto:contact@piperstitch.com?subject=PiperStitch%20stopped">Tell us what you were doing</a>
        </div>
      </div>
    );
  }
}
