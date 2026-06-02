## Hướng dẫn dùng Claude Desktop để tra cứu JIRA và Confluence

Tài liệu này giúp em kết nối Claude Desktop với hệ thống JIRA và Confluence của VNPay, để hỏi Claude về tiến độ công việc, phân công, và nội dung trang wiki. Claude chỉ xem thông tin, không chỉnh sửa gì cả.

## Chuẩn bị

- Đã cài Claude Desktop trên máy.
- Có tài khoản GitHub và đã được cấp quyền truy cập. Nếu chưa, hãy nhắn cho người quản trị kèm tên đăng nhập GitHub của bạn.

## Các bước kết nối

1. Mở Claude, vào Customize (Tùy chỉnh) > Connectors (Trình kết nối).
2. Bấm dấu **+**, rồi chọn **Add custom connector** (Thêm trình kết nối tùy chỉnh).
3. Điền tên `VNPay Atlassian` vào ô Name (Tên), rồi dán địa chỉ này vào ô URL (không cần điền gì ở phần Advanced settings):

   ```
   https://vnpay-atlassian-mcp.politeisland-ad6a6562.southeastasia.azurecontainerapps.io/mcp
   ```

4. Ở mục phê duyệt **Need approvals** (Cần phê duyệt), đổi sang **Always allow** (Luôn cho phép) để Claude không phải hỏi xác nhận mỗi lần tra cứu.
5. Bấm **Add** (Thêm). Một cửa sổ trình duyệt sẽ mở ra để bạn đăng nhập GitHub; bấm đồng ý cấp quyền.
6. Xong. Trình kết nối đã được thêm và bạn không phải đăng nhập lại ở những lần sau.

## Bật trình kết nối trong cuộc trò chuyện

Trong mỗi cuộc trò chuyện, bấm dấu **+** ở góc dưới bên trái khung chat, chọn **Connectors**, rồi bật `VNPay Atlassian`. Sau đó bạn có thể hỏi Claude về JIRA và Confluence.

## Bạn có thể hỏi gì

- "Liệt kê các công việc đang làm dở (In Progress)."
- "Tổng hợp tiến độ và người phụ trách của dự án VNPSHOPNEW."
- "Các công việc ưu tiên cao trong dự án VNPVNCALL hiện đang làm là gì?"
- "Trang Confluence này có thay đổi gì so với phiên bản trước?"

## Nếu gặp trục trặc

- Đăng nhập xong nhưng không tra cứu được: tài khoản GitHub của bạn chưa được cấp quyền. Hãy nhắn người quản trị kèm tên đăng nhập GitHub của bạn.
- Không kết nối được: thử lại sau ít phút; nếu vẫn không được, báo người quản trị.
- Muốn đổi sang tài khoản GitHub khác: vào Customize > Connectors, xóa trình kết nối rồi thêm lại theo các bước trên.
- Không thấy trình kết nối để bật trong cuộc trò chuyện: kiểm tra lại đã thêm ở Customize > Connectors chưa. Nếu công ty dùng gói Team/Enterprise, người quản trị (Owner) cần thêm trình kết nối ở Organization settings > Connectors trước, sau đó bạn vào Customize > Connectors và bấm Connect để đăng nhập.
- Bất cứ lúc nào cần giúp, cứ nhắn anh. Anh luôn ở đây.
