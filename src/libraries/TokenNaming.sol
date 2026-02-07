// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title TokenNaming
 * @author Yield Forge Team
 * @notice Utilities for PT/YT token naming and maturity date calculations
 * @dev Used by LiquidityFacet for automatic cycle creation
 *
 * TOKEN NAMING FORMAT:
 * --------------------
 * Full name: YF-PT-[HASH6]-[DDMMMYYYY]
 * Symbol:    YF-PT-[HASH6]-[DDMMMYYYY]
 *
 * Components:
 * - YF = Yield Forge brand identifier
 * - PT/YT = Token type (Principal Token / Yield Token)
 * - HASH6 = 6-character uppercase hex hash of poolId
 * - DDMMMYYYY = Maturity date (e.g., 31MAR2025, 15JUN2025)
 *
 * Examples:
 * - YF-PT-A3F2E9-31MAR2025 (Principal Token maturing March 31, 2025)
 * - YF-YT-A3F2E9-31MAR2025 (Yield Token for same cycle)
 *
 * MATURITY DATES:
 * ---------------
 * Each cycle lasts ~90 days from its start date.
 * Unlike quarterly standardized dates, each pool has individual maturity.
 * This ensures fair duration for all users regardless of when they join.
 *
 * Example:
 * - Pool created Jan 15 → Maturity Apr 15 (90 days)
 * - Pool created Feb 1 → Maturity May 2 (90 days)
 *
 * DATE FUNCTIONS:
 * ---------------
 * This library includes a complete Gregorian calendar implementation:
 * - getYear(), getMonth(), getDay() - Extract date components
 * - toTimestamp() - Convert date to Unix timestamp
 * - isLeapYear() - Check for leap years
 * - getLastDayOfMonth() - Get month length
 */
library TokenNaming {
    // ============================================================
    //                     HASH GENERATION
    // ============================================================

    /**
     * @notice Convert poolId to 6-character uppercase hex hash
     * @dev Takes first 3 bytes of keccak256 hash, converts to 6 hex chars
     *
     * Algorithm:
     * 1. Hash the poolId with keccak256
     * 2. Take first 3 bytes (24 bits)
     * 3. Convert each byte to 2 hex characters
     * 4. Use uppercase (A-F, not a-f)
     *
     * @param poolId The pool identifier (bytes32)
     * @return 6-character uppercase hex string (e.g., "A3F2E9")
     *
     * Example:
     *   poolId = 0x1234...
     *   hash = keccak256(poolId) = 0xA3F2E9...
     *   result = "A3F2E9"
     */
    function poolIdToShortHash(
        bytes32 poolId
    ) internal pure returns (string memory) {
        // Hash the poolId to get a random distribution
        bytes memory hashBytes = abi.encodePacked(
            keccak256(abi.encodePacked(poolId))
        );

        // Prepare result array for 6 characters
        bytes memory result = new bytes(6);

        // Hex character lookup table (uppercase)
        bytes memory hexChars = "0123456789ABCDEF";

        // Convert first 3 bytes to 6 hex characters
        // Each byte becomes 2 hex chars (high nibble + low nibble)
        for (uint256 i = 0; i < 3; i++) {
            // High nibble (upper 4 bits)
            result[i * 2] = hexChars[uint8(hashBytes[i]) >> 4];
            // Low nibble (lower 4 bits)
            result[i * 2 + 1] = hexChars[uint8(hashBytes[i]) & 0x0f];
        }

        return string(result);
    }

    // ============================================================
    //                   MATURITY CALCULATION
    // ============================================================

    /**
     * @notice Calculate maturity date (90 days from start)
     * @dev Each cycle has individual maturity, not standardized quarters
     *
     * @param startTimestamp When the cycle starts (usually block.timestamp)
     * @return maturityDate Unix timestamp of maturity (end of day)
     *
     * Example:
     *   start = Jan 15, 2025 12:00 UTC
     *   maturity = Apr 15, 2025 23:59:59 UTC
     */
    function calculateMaturity(
        uint256 startTimestamp
    ) internal pure returns (uint256) {
        // Add 90 days to start timestamp
        uint256 maturityTimestamp = startTimestamp + 90 days;

        // Normalize to end of day (23:59:59 UTC)
        // This ensures consistent maturity times across all pools
        uint256 year = getYear(maturityTimestamp);
        uint256 month = getMonth(maturityTimestamp);
        uint256 day = getDay(maturityTimestamp);

        // Convert to start of day, then add 1 day - 1 second
        return toTimestamp(year, month, day) + 1 days - 1;
    }

    // ============================================================
    //                    DATE FORMATTING
    // ============================================================

    /**
     * @notice Format maturity date as "DDMMMYYYY"
     * @dev Returns human-readable date for token names
     *
     * @param timestamp Unix timestamp to format
     * @return Formatted string like "31MAR2025", "15JUN2025"
     *
     * Examples:
     *   timestamp for Mar 31, 2025 → "31MAR2025"
     *   timestamp for Jun 15, 2025 → "15JUN2025"
     *   timestamp for Jan 1, 2026 → "01JAN2026"
     */
    function formatMaturityDate(
        uint256 timestamp
    ) internal pure returns (string memory) {
        uint256 year = getYear(timestamp);
        uint256 month = getMonth(timestamp);
        uint256 day = getDay(timestamp);

        // Month abbreviations (3 letters, uppercase)
        string[12] memory monthNames = [
            "JAN",
            "FEB",
            "MAR",
            "APR",
            "MAY",
            "JUN",
            "JUL",
            "AUG",
            "SEP",
            "OCT",
            "NOV",
            "DEC"
        ];

        // Combine: DD + MMM + YYYY
        return
            string(
                abi.encodePacked(
                    padDay(day), // "01" to "31"
                    monthNames[month - 1], // "JAN" to "DEC"
                    uint2str(year) // "2025"
                )
            );
    }

    /**
     * @notice Pad day number to 2 digits
     * @dev Adds leading zero for days 1-9
     *
     * @param day Day of month (1-31)
     * @return 2-character string ("01" to "31")
     */
    function padDay(uint256 day) internal pure returns (string memory) {
        if (day < 10) {
            return string(abi.encodePacked("0", uint2str(day)));
        }
        return uint2str(day);
    }

    // ============================================================
    //                  DATE COMPONENT EXTRACTION
    // ============================================================

    /**
     * @notice Get year from Unix timestamp
     * @dev Uses Gregorian calendar algorithm
     *
     * Algorithm: Converts days since epoch to Julian Day Number,
     * then extracts year using standard astronomical formula.
     *
     * @param timestamp Unix timestamp (seconds since Jan 1, 1970)
     * @return Year (e.g., 2025)
     */
    function getYear(uint256 timestamp) internal pure returns (uint256) {
        uint256 SECONDS_PER_DAY = 86400;
        uint256 OFFSET19700101 = 2440588; // Julian day of Unix epoch

        uint256 _days = timestamp / SECONDS_PER_DAY;

        // Convert to Julian Day Number and extract year
        uint256 L = _days + 68569 + OFFSET19700101;
        uint256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        uint256 _year = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * _year) / 4 + 31;
        uint256 _month = (80 * L) / 2447;
        L = _month / 11;
        _year = 100 * (N - 49) + _year + L;

        return _year;
    }

    /**
     * @notice Get month from Unix timestamp (1-12)
     * @dev January = 1, December = 12
     *
     * @param timestamp Unix timestamp
     * @return Month number (1-12)
     */
    function getMonth(uint256 timestamp) internal pure returns (uint256) {
        uint256 SECONDS_PER_DAY = 86400;
        uint256 OFFSET19700101 = 2440588;

        uint256 _days = timestamp / SECONDS_PER_DAY;

        uint256 L = _days + 68569 + OFFSET19700101;
        uint256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        uint256 _year = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * _year) / 4 + 31;
        uint256 _month = (80 * L) / 2447;
        L = _month / 11;
        _month = _month + 2 - 12 * L;

        return _month;
    }

    /**
     * @notice Get day of month from Unix timestamp (1-31)
     *
     * @param timestamp Unix timestamp
     * @return Day of month (1-31)
     */
    function getDay(uint256 timestamp) internal pure returns (uint256) {
        uint256 SECONDS_PER_DAY = 86400;
        uint256 OFFSET19700101 = 2440588;

        uint256 _days = timestamp / SECONDS_PER_DAY;

        uint256 L = _days + 68569 + OFFSET19700101;
        uint256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        uint256 _year = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * _year) / 4 + 31;
        uint256 _month = (80 * L) / 2447;
        uint256 _day = L - (2447 * _month) / 80;

        return _day;
    }

    // ============================================================
    //                   DATE UTILITY FUNCTIONS
    // ============================================================

    /**
     * @notice Get last day of a given month
     * @dev Handles February leap years correctly
     *
     * @param year The year (e.g., 2025)
     * @param month The month (1-12)
     * @return Last day of month (28, 29, 30, or 31)
     */
    function getLastDayOfMonth(
        uint256 year,
        uint256 month
    ) internal pure returns (uint256) {
        // February special case
        if (month == 2) {
            return isLeapYear(year) ? 29 : 28;
        }

        // 30-day months: April, June, September, November
        if (month == 4 || month == 6 || month == 9 || month == 11) {
            return 30;
        }

        // All other months have 31 days
        return 31;
    }

    /**
     * @notice Convert year/month/day to Unix timestamp
     * @dev Returns timestamp for 00:00:00 UTC of the given date
     *
     * @param year Year (e.g., 2025)
     * @param month Month (1-12)
     * @param day Day (1-31)
     * @return Unix timestamp
     */
    function toTimestamp(
        uint256 year,
        uint256 month,
        uint256 day
    ) internal pure returns (uint256) {
        // Calculate days from year
        uint256 timestamp = yearToDays(year) * 86400;

        // Days in each month (non-leap year baseline)
        uint256[12] memory daysInMonth = [
            uint256(31), // January
            28, // February (adjusted below for leap years)
            31, // March
            30, // April
            31, // May
            30, // June
            31, // July
            31, // August
            30, // September
            31, // October
            30, // November
            31 // December
        ];

        // Adjust February for leap years
        if (isLeapYear(year)) {
            daysInMonth[1] = 29;
        }

        // Add days from completed months
        for (uint256 i = 0; i < month - 1; i++) {
            timestamp += daysInMonth[i] * 86400;
        }

        // Add days in current month (day is 1-indexed, so subtract 1)
        timestamp += (day - 1) * 86400;

        return timestamp;
    }

    /**
     * @notice Check if a year is a leap year
     * @dev Gregorian calendar rules:
     *      - Divisible by 4: leap year
     *      - Except divisible by 100: not leap year
     *      - Except divisible by 400: leap year
     *
     * @param year The year to check
     * @return True if leap year
     *
     * Examples:
     *   2024 → true (divisible by 4)
     *   2100 → false (divisible by 100, not by 400)
     *   2000 → true (divisible by 400)
     */
    function isLeapYear(uint256 year) internal pure returns (bool) {
        if (year % 4 != 0) return false;
        if (year % 100 != 0) return true;
        if (year % 400 != 0) return false;
        return true;
    }

    /**
     * @notice Calculate total days from Unix epoch (1970) to start of year
     * @dev Counts all days in years before the given year
     *
     * @param year The target year
     * @return Total days from Jan 1, 1970 to Jan 1 of target year
     */
    function yearToDays(uint256 year) internal pure returns (uint256) {
        uint256 totalDays = 0;

        // Count days in each year from 1970 to target year
        for (uint256 y = 1970; y < year; y++) {
            totalDays += isLeapYear(y) ? 366 : 365;
        }

        return totalDays;
    }

    // ============================================================
    //                   STRING UTILITIES
    // ============================================================

    /**
     * @notice Convert unsigned integer to string
     * @dev Standard uint to string conversion
     *
     * @param value The number to convert
     * @return String representation
     *
     * Examples:
     *   0 → "0"
     *   42 → "42"
     *   2025 → "2025"
     */
    function uint2str(uint256 value) internal pure returns (string memory) {
        // Special case for zero
        if (value == 0) return "0";

        // Count digits
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }

        // Build string from right to left
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (value % 10))); // ASCII '0' = 48
            value /= 10;
        }

        return string(buffer);
    }
}
