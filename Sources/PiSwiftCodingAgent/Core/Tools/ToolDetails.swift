import Foundation
import PiSwiftAI

public func truncationToAnyCodable(_ truncation: TruncationResult) -> AnyCodable {
    AnyCodable([
        "content": truncation.content,
        "truncated": truncation.truncated,
        "truncatedBy": truncation.truncatedBy ?? NSNull(),
        "totalLines": truncation.totalLines,
        "totalBytes": truncation.totalBytes,
        "outputLines": truncation.outputLines,
        "outputBytes": truncation.outputBytes,
        "lastLinePartial": truncation.lastLinePartial,
        "firstLineExceedsLimit": truncation.firstLineExceedsLimit,
        "maxLines": truncation.maxLines,
        "maxBytes": truncation.maxBytes,
    ])
}
