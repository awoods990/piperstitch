import type { CatalogSize } from "../types";
import { hoopGroups } from "../hoops";
import { cm } from "../format";

/** One <select> of every hoop, grouped by line -- used in the toolbar and
 *  the Inspector so both offer exactly the same list the same way. */
export function HoopSelect({ hoops, value, onChange, withSizes }: {
  hoops: CatalogSize[]; value: CatalogSize | null; onChange: (h: CatalogSize | null) => void; withSizes?: boolean;
}) {
  return (
    <select value={value?.name ?? ""} onChange={(e) => onChange(hoops.find((x) => x.name === e.target.value) ?? null)}>
      <option value="">None (no fit check)</option>
      {hoopGroups(hoops).map(([group, list]) => (
        <optgroup key={group} label={group}>
          {list.map((x) => (
            <option key={x.name} value={x.name}>
              {x.name.replace(/^(Mighty Hoop|Durkee EZ Frame) /, "")}{withSizes ? ` — ${cm(x.widthMM)} × ${cm(x.heightMM)} cm` : ""}
            </option>
          ))}
        </optgroup>
      ))}
    </select>
  );
}
