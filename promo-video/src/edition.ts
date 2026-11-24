import React from 'react';

/**
 * True inside the tour film, which describes AXe as it is now: no version numbers, no "new in",
 * and no comparisons with earlier releases. The 2.0 release film leaves it false.
 */
export const Versionless = React.createContext(false);
export const useVersionless = () => React.useContext(Versionless);
