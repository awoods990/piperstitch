import type { CatalogSize } from "../types";
import { hoopGroups } from "../hoops";
import { size } from "../format";

/** One <select> of every hoop, grouped by line -- used in the toolbar and
 *  the Inspector so both offer exactly the same list the same way. */
export function HoopSelect({ hoops, value, onChange, withSizes, ownedNames }: {
  hoops: CatalogSize[]; value: CatalogSize | null; onChange: (h: CatalogSize | null) => void; withSizes?: boolean; ownedNames?: string[];
}) {
  return (
    <select value={value?.name ?? ""} onChange={(e) => onChange(hoops.find((x) => x.name === e.target.value) ?? null)}>
      <option value="">None (no fit check)</option>
      {hoopGroups(hoops, ownedNames ?? []).map(([group, list]) => (
        <optgroup key={group} label={group}>
          {list.map((x) => (
            <option key={x.name} value={x.name}>
              {x.name.replace(/^(Mighty Hoop|Durkee EZ Frame) /, "")}{withSizes ? ` — ${size(x.widthMM, x.heightMM)}` : ""}
            </option>
          ))}
        </optgroup>
      ))}
    </select>
  );
}
