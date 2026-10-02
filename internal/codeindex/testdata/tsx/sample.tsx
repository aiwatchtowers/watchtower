// A tiny TSX fixture for the full grammar set.

import { useState } from "react";

/** The props a counter takes. */
export interface CounterProps {
  /** The value to start from. */
  start: number;
}

/** A label, as a string. */
type Label = string;

/** A counter button. */
export function Counter({ start }: CounterProps) {
  const [count, setCount] = useState(start);
  return <button onClick={() => setCount(count + 1)}>{count}</button>;
}

/** Shows a label. */
export const Badge = ({ label }: { label: Label }) => <span>{label}</span>;

/** A class component. */
export class Panel extends Component<CounterProps> {
  render() {
    return <div>{this.props.start}</div>;
  }
}
