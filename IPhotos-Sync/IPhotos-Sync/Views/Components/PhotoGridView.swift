import SwiftUI

struct PhotoGridView: View {
    let photos: [PhotoAsset]

    private let columns = [
        GridItem(.adaptive(minimum: Constants.UI.thumbnailSize), spacing: Constants.UI.gridSpacing)
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.fixed(Constants.UI.thumbnailSize))], spacing: Constants.UI.gridSpacing) {
                ForEach(photos) { photo in
                    PhotoThumbnailView(photo: photo)
                }
            }
            .padding(.horizontal)
        }
    }
}

struct PhotoThumbnailView: View {
    @ObservedObject var photo: PhotoAsset

    var body: some View {
        ZStack {
            if let thumbnail = photo.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Constants.UI.thumbnailSize, height: Constants.UI.thumbnailSize)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: Constants.UI.thumbnailSize, height: Constants.UI.thumbnailSize)
                ProgressView()
            }

            statusOverlay
        }
        .cornerRadius(8)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch photo.uploadStatus {
        case .pending:
            EmptyView()
        case .uploading(let progress):
            ZStack {
                Color.black.opacity(0.4)
                CircularProgressView(progress: progress)
            }
        case .uploaded:
            ZStack {
                Color.green.opacity(0.4)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.white)
                    .font(.title2)
            }
        case .failed:
            ZStack {
                Color.red.opacity(0.4)
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .font(.title2)
            }
        }
    }
}

struct CircularProgressView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: 3)
                .frame(width: 30, height: 30)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 30, height: 30)
                .rotationEffect(.degrees(-90))

            Text("\(Int(progress * 100))%")
                .font(.system(size: 8))
                .foregroundColor(.white)
                .fontWeight(.bold)
        }
    }
}

#if DEBUG
struct PhotoGridView_Previews: PreviewProvider {
    static var previews: some View {
        PhotoGridView(photos: [])
    }
}
#endif
